## Nim-LibP2P
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options
import strutils, sequtils, tables
import chronos, chronicles

import ./voucher,
       ../../peerinfo,
       ../../switch,
       ../../multiaddress,
       ../../multicodec,
       ../../stream/connection,
       ../../protocols/protocol,
       ../../transports/transport,
       ../../errors,
       ../../signed_envelope

# TODO:
# * Eventually replace std/times by chronos/timer. Currently chronos/timer
#   doesn't offer the possibility to get a datetime in UNIX UTC
# * Eventually add an access control list in the handleReserve and
#   handleConnect of the Relay
# * When the circuit relay v1 will be merged with unstable:
#   + add a backward compatibility on the RelayV2Transport
#   + remove the two Pattern
# * Optimize the limit in the encoding part of the hop / stop message
# * Better reservation management ie find a way to re-reserve when the end is
#   nigh
import std/times
export chronicles

const
  RelayV2HopCodec* = "/libp2p/circuit/relay/0.2.0/hop"
  RelayV2StopCodec* = "/libp2p/circuit/relay/0.2.0/stop"
  MsgSize* = 4096
  DefaultReservationTTL* = initDuration(hours = 1)
  DefaultLimitDuration* = 120
  DefaultLimitData* = 1 shl 17
  DefaultHeartbeatSleepTime = 1
  MaxCircuit* = 1024
  MaxCircuitPerPeer* = 64

logScope:
  topics = "libp2p relayv2"

type
  RelayV2Error* = object of LPError
  RelayV2Status* = enum
    Ok = 100
    ReservationRefused = 200
    ResourceLimitExceeded = 201
    PermissionDenied = 202
    ConnectionFailed = 203
    NoReservation = 204
    MalformedMessage = 400
    UnexpectedMessage = 401
  HopMessageType* {.pure.} = enum
    Reserve = 0
    Connect = 1
    Status = 2
  HopMessage* = object
    msgType*: HopMessageType
    peer*: Option[RelayV2Peer]
    reservation*: Option[Reservation]
    limit*: Option[RelayV2Limit]
    status*: Option[RelayV2Status]

  StopMessageType* {.pure.} = enum
    Connect = 0
    Status = 1
  StopMessage* = object
    msgType*: StopMessageType
    peer*: Option[RelayV2Peer]
    limit*: Option[RelayV2Limit]
    status*: Option[RelayV2Status]

  RelayV2Peer* = object
    peerId*: PeerID
    addrs*: seq[MultiAddress]
  Reservation* = object
    expire: uint64              # required, Unix expiration time (UTC)
    addrs: seq[MultiAddress]    # relay address for reserving peer
    svoucher: Option[seq[byte]] # optional, reservation voucher
  RelayV2Limit* = object
    duration: uint32            # seconds
    data: uint64                # bytes

  RelayV2* = ref object of LPProtocol
    switch: Switch
    peerId: PeerID
    rsvp: Table[PeerId, DateTime]

    streamCount: int
    peerCount: CountTable[PeerId]

    heartbeatFut: Future[void]

    reservationTTL*: times.Duration
    limit*: RelayV2Limit
    heartbeatSleepTime*: uint32
    maxCircuit*: int
    maxCircuitPerPeer*: int
    msgSize*: int

# Relay Connection

type
  RelayConnection = ref object of Connection
    conn*: Connection
    limitDuration: uint32
    limitData: uint64
    dataSent: uint64

method readOnce*(
  self: RelayConnection,
  pbytes: pointer,
  nbytes: int):
  Future[int] {.async.} =
  return await self.conn.readOnce(pbytes, nbytes)

method write*(self: RelayConnection, msg: seq[byte]): Future[void] {.async.} =
  self.dataSent.inc(msg.len)
  if self.limitData != 0 and self.dataSent > self.limitData:
    await self.close()
    return
  await self.conn.write(msg)

method closeImpl*(self: RelayConnection): Future[void] {.async.} =
  await self.conn.closeImpl()
  await procCall Connection(self).closeImpl()

method isCircuitRelay*(self: RelayConnection): bool = true

proc new*(
  T: typedesc[RelayConnection],
  conn: Connection,
  limitDuration: uint32,
  limitData: uint64): T =
  let rv = T(conn: conn, limitDuration: limitDuration, limitData: limitData)
  rv.initStream()
  if limitDuration > 0:
    asyncSpawn (proc () {.async.} =
      await sleepAsync(limitDuration.seconds()) or conn.join()
      await conn.close())()
  return rv

# Hop Protocol

proc encodeHopMessage*(msg: HopMessage): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write(1, msg.msgType.ord.uint)
  if msg.peer.isSome():
    var ppb = initProtoBuffer()
    ppb.write(1, msg.peer.get().peerId)
    for ma in msg.peer.get().addrs:
      ppb.write(2, ma.data.buffer)
    ppb.finish()
    pb.write(2, ppb.buffer)
  if msg.reservation.isSome():
    let rsrv = msg.reservation.get()
    var rpb = initProtoBuffer()
    rpb.write(1, rsrv.expire)
    for ma in rsrv.addrs:
      rpb.write(2, ma.data.buffer)
    if rsrv.svoucher.isSome():
      rpb.write(3, rsrv.svoucher.get())
    rpb.finish()
    pb.write(3, rpb.buffer)
  if msg.limit.isSome():
    let limit = msg.limit.get()
    var lpb = initProtoBuffer()
    lpb.write(1, limit.duration)
    lpb.write(2, limit.data)
    lpb.finish()
    pb.write(4, lpb.buffer)
  if msg.status.isSome():
    pb.write(5, msg.status.get().ord.uint)

  pb.finish()
  pb

proc decodeHopMessage(buf: seq[byte]): Option[HopMessage] =
  var
    msg: HopMessage
    msgTypeOrd: uint32
    pbPeer: ProtoBuffer
    pbReservation: ProtoBuffer
    pbLimit: ProtoBuffer
    statusOrd: uint32
    peer: RelayV2Peer
    reservation: Reservation
    limit: RelayV2Limit
    res: bool

  let
    pb = initProtoBuffer(buf)
    r1 = pb.getRequiredField(1, msgTypeOrd)
    r2 = pb.getField(2, pbPeer)
    r3 = pb.getField(3, pbReservation)
    r4 = pb.getField(4, pbLimit)
    r5 = pb.getField(5, statusOrd)

  if r1.isErr() or r2.isErr() or r3.isErr() or r4.isErr() or r5.isErr():
    return none(HopMessage)

  if r2.get() and
     (pbPeer.getRequiredField(1, peer.peerId).isErr() or
      pbPeer.getRepeatedField(2, peer.addrs).isErr()):
    return none(HopMessage)

  if r3.get():
    var svoucher: seq[byte]
    let rSVoucher = pbReservation.getField(3, svoucher)
    if pbReservation.getRequiredField(1, reservation.expire).isErr() or
       pbReservation.getRepeatedField(2, reservation.addrs).isErr() or
       rSVoucher.isErr():
      return none(HopMessage)
    if rSVoucher.get(): reservation.svoucher = some(svoucher)

  if r4.get() and
     (pbLimit.getField(1, limit.duration).isErr() or
      pbLimit.getField(1, limit.data).isErr()):
    return none(HopMessage)

  msg.msgType = HopMessageType(msgTypeOrd)
  if r2.get(): msg.peer = some(peer)
  if r3.get(): msg.reservation = some(reservation)
  if r4.get(): msg.limit = some(limit)
  if r5.get(): msg.status = some(RelayV2Status(statusOrd))
  some(msg)

proc handleHopError*(conn: Connection, code: RelayV2Status) {.async, gcsafe.} =
  trace "send hop status", status = $code & "(" & $ord(code) & ")"
  let
    msg = HopMessage(msgType: HopMessageType.Status, status: some(code))
    pb = encodeHopMessage(msg)

  try:
    await conn.writeLp(pb.buffer)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing error msg", exc=exc.msg, code

# Stop Message

proc encodeStopMessage(msg: StopMessage): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write(1, msg.msgType.ord.uint)
  if msg.peer.isSome():
    var ppb = initProtoBuffer()
    ppb.write(1, msg.peer.get().peerId)
    for ma in msg.peer.get().addrs:
      ppb.write(2, ma.data.buffer)
    ppb.finish()
    pb.write(2, ppb.buffer)
  if msg.limit.isSome():
    var lpb = initProtoBuffer()
    let limit = msg.limit.get()
    lpb.write(1, limit.duration)
    lpb.write(2, limit.data)
    lpb.finish()
    pb.write(3, lpb.buffer)
  if msg.status.isSome():
    pb.write(4, msg.status.get().ord.uint)

  pb.finish()
  pb

proc decodeStopMessage(buf: seq[byte]): Option[StopMessage] =
  var
    msg: StopMessage
    msgTypeOrd: uint32
    pbPeer: ProtoBuffer
    pbLimit: ProtoBuffer
    statusOrd: uint32
    peer: RelayV2Peer
    limit: RelayV2Limit
    rVoucher: ProtoResult[bool]
    res: bool

  let
    pb = initProtoBuffer(buf)
    r1 = pb.getRequiredField(1, msgTypeOrd)
    r2 = pb.getField(2, pbPeer)
    r3 = pb.getField(3, pbLimit)
    r4 = pb.getField(4, statusOrd)

  if r1.isErr() or r2.isErr() or r3.isErr() or r4.isErr():
    return none(StopMessage)

  if r2.get() and
     (pbPeer.getRequiredField(1, peer.peerId).isErr() or
      pbPeer.getRepeatedField(2, peer.addrs).isErr()):
    return none(StopMessage)

  if r3.get() and
     (pbLimit.getField(1, limit.duration).isErr() or
      pbLimit.getField(2, limit.data).isErr()):
    return none(StopMessage)

  msg.msgType = StopMessageType(msgTypeOrd)
  if r2.get(): msg.peer = some(peer)
  if r3.get(): msg.limit = some(limit)
  if r4.get(): msg.status = some(RelayV2Status(statusOrd))
  some(msg)

# Protocols

proc createHopMessage(
    rv2: RelayV2,
    pid: PeerID,
    expire: DateTime): Result[HopMessage, CryptoError] =
  var msg: HopMessage
  let
    expireUnix = expire.toTime.toUnix.uint64
    v = Voucher(relayPeerId: rv2.switch.peerInfo.peerId,
                  reservingPeerId: pid,
                  expiration: expireUnix)
    sv = ? SignedVoucher.init(rv2.switch.peerInfo.privateKey, v)
    ma = MultiAddress.init("/p2p/" & $rv2.switch.peerInfo.peerId).tryGet()
  msg.reservation = some(Reservation(expire: expireUnix,
                         addrs: rv2.switch.peerInfo.addrs.mapIt(it & ma),
                         svoucher: some(? sv.encode)))
  msg.limit = some(rv2.limit)
  msg.msgType = HopMessageType.Status
  msg.status = some(Ok)
  return ok(msg)

proc handleReserve(rv2: RelayV2, conn: Connection) {.async, gcsafe.} =
  let pid = conn.peerId

  if conn.isCircuitRelay():
    trace "reservation attempt over relay connection", pid
    await handleHopError(conn, RelayV2Status.PermissionDenied)
    return

  let expire = now().utc + rv2.reservationTTL
  rv2.rsvp[pid] = expire

  trace "reserving relay slot for", pid

  let msg = rv2.createHopMessage(pid, expire)
  if msg.isErr():
    trace "error signing the voucher", error = error(msg), pid
    # conn.reset()
    return
  let pb = encodeHopMessage(msg.get())

  try:
    await conn.writeLp(pb.buffer)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing reservation response", exc=exc.msg, retractedPid = pid
    # conn.reset()

proc handleConnect(rv2: Relayv2,
                   conn: Connection,
                   msg: HopMessage) {.async, gcsafe.} =
  rv2.streamCount.inc()
  defer: rv2.streamCount.dec()

  if rv2.streamCount > rv2.maxCircuit:
    trace "refusing connection; too many active circuit"
    await handleHopError(conn, RelayV2Status.ResourceLimitExceeded)
    return

  let src = conn.peerId

  if msg.peer.isNone():
    await handleHopError(conn, RelayV2Status.MalformedMessage)
    return

  let dst = msg.peer.get()

  if conn.isCircuitRelay():
    trace "connection attempt over relay connection", src = conn.peerId
    await handleHopError(conn, RelayV2Status.PermissionDenied)
    return

  if dst.peerId notin rv2.rsvp:
    trace "refusing connection, no reservation", src, dst = dst.peerId
    await handleHopError(conn, RelayV2Status.NoReservation)
    return

  rv2.peerCount.inc(src)
  rv2.peerCount.inc(dst.peerId)
  defer:
    rv2.peerCount.inc(src, -1)
    rv2.peerCount.inc(dst.peerId, -1)

  if rv2.peerCount[src] > rv2.maxCircuitPerPeer or
     rv2.peerCount[dst.peerId] > rv2.maxCircuitPerPeer:
    trace "too many connections", src = rv2.peerCount[src],
                                  dst = rv2.peerCount[dst.peerId],
                                  max = rv2.maxCircuitPerPeer
    await handleHopError(conn, RelayV2Status.ResourceLimitExceeded)
    return

  let connDst = try:
    await rv2.switch.dial(dst.peerId, RelayV2StopCodec)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error opening relay stream", dst, exc=exc.msg
    await handleHopError(conn, RelayV2Status.ConnectionFailed)
    return
  defer:
    await connDst.close()

  let stopMsgToSend = StopMessage(msgType: StopMessageType.Connect,
                          peer: some(RelayV2Peer(peerId: src, addrs: @[])),
                          limit: some(rv2.limit))

  try:
    await connDst.writeLp(encodeStopMessage(stopMsgToSend).buffer)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing stop handshake", exc=exc.msg
    await handleHopError(conn, RelayV2Status.ConnectionFailed)
    return

  let msgRcvFromDstOpt = try:
    decodeStopMessage(await connDst.readLp(rv2.msgSize))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error reading stop response", exc=exc.msg
    await handleHopError(conn, RelayV2Status.ConnectionFailed)
    return

  if msgRcvFromDstOpt.isNone():
    trace "error reading stop response", msg = msgRcvFromDstOpt
    await handleHopError(conn, RelayV2Status.ConnectionFailed)
    return

  let msgRcvFromDst = msgRcvFromDstOpt.get()
  if msgRcvFromDst.msgType != StopMessageType.Status:
    trace "unexpected stop response, not a status message",
          msgType = msgRcvFromDst.msgType
    await handleHopError(conn, RelayV2Status.ConnectionFailed)
    return

  if msgRcvFromDst.status.isNone() or
     msgRcvFromDst.status.get() != RelayV2Status.Ok:
    trace "relay stop failure", status = msgRcvFromDst.status
    await handleHopError(conn, RelayV2Status.ConnectionFailed)
    return

  let resp = HopMessage(msgType: HopMessageType.Status,
                        status: some(RelayV2Status.Ok))
  try:
    await conn.writeLp(encodeHopMessage(resp).buffer)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing relay response", exc=exc.msg
    return

  trace "relaying connection", src, dst

  proc bridge(conn: Connection, connDst: Connection) {.async.} =
    const bufferSize = 4096
    var
      bufSrcToDst: array[bufferSize, byte]
      bufDstToSrc: array[bufferSize, byte]
      futSrc = conn.readOnce(addr bufSrcToDst[0], bufSrcToDst.len)
      futDst = connDst.readOnce(addr bufDstToSrc[0], bufDstToSrc.len)
      bytesSendFromSrcToDst = 0
      bytesSendFromDstToSrc = 0
      bufRead: int

    while not conn.closed() and not connDst.closed():
      try:
        await futSrc or futDst
        if futSrc.finished():
          bufRead = await futSrc
          assert bufRead <= bufferSize
          bytesSendFromSrcToDst.inc(bufRead)
          await connDst.write(@bufSrcToDst[0..<bufRead])
          zeroMem(addr(bufSrcToDst), bufferSize)
          futSrc = conn.readOnce(addr bufSrcToDst[0], bufSrcToDst.len)
        if futDst.finished():
          bufRead = await futDst
          assert bufRead <= bufferSize
          bytesSendFromDstToSrc += bufRead
          await conn.write(bufDstToSrc[0..<bufRead])
          zeroMem(addr(bufDstToSrc), bufferSize)
          futDst = connDst.readOnce(addr bufDstToSrc[0], bufDstToSrc.len)
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        if conn.closed() or conn.atEof():
          trace "relay src closed connection", src
        if connDst.closed() or connDst.atEof():
          trace "relay dst closed connection", dst
        trace "relay error", exc=exc.msg
        break

    trace "end relaying", bytesSendFromSrcToDst, bytesSendFromDstToSrc

    await futSrc.cancelAndWait()
    await futDst.cancelAndWait()
  await bridge(RelayConnection.new(conn, rv2.limit.duration, rv2.limit.data),
               RelayConnection.new(connDst, rv2.limit.duration, rv2.limit.data))


proc heartbeat(rv2: RelayV2) {.async.} =
  while true:
    let n = now().utc
    var rsvp = rv2.rsvp
    for k, v in rv2.rsvp.mpairs:
      if n > v:
        rsvp.del(k)
    rv2.rsvp = rsvp

    await sleepAsync(chronos.seconds(rv2.heartbeatSleepTime))


proc new*(T: typedesc[RelayV2], switch: Switch,
     reservationTTL: times.Duration = DefaultReservationTTL,
     limitDuration: uint32 = DefaultLimitDuration,
     limitData: uint64 = DefaultLimitData,
     heartbeatSleepTime: uint32 = DefaultHeartbeatSleepTime,
     maxCircuit: int = MaxCircuit,
     maxCircuitPerPeer: int = MaxCircuitPerPeer,
     msgSize: int = MsgSize): T =

  let rv2 = T(switch: switch,
    codecs: @[RelayV2HopCodec],
    reservationTTL: reservationTTL,
    limit: RelayV2Limit(duration: limitDuration, data: limitData),
    heartbeatSleepTime: heartbeatSleepTime,
    maxCircuit: maxCircuit,
    maxCircuitPerPeer: maxCircuitPerPeer,
    msgSize: msgSize)

  proc handleStream(conn: Connection, proto: string) {.async, gcsafe.} =
    try:
      let msgOpt = decodeHopMessage(await conn.readLp(rv2.msgSize))

      if msgOpt.isNone():
        await handleHopError(conn, RelayV2Status.MalformedMessage)
        return
      else:
        trace "relayv2 handle stream", msg = msgOpt.get()
      let msg = msgOpt.get()

      case msg.msgType:
        of HopMessageType.Reserve: await rv2.handleReserve(conn)
        of HopMessageType.Connect: await rv2.handleConnect(conn, msg)
        else:
          trace "Unexpected relayv2 handshake", msgType=msg.msgType
          await handleHopError(conn, RelayV2Status.MalformedMessage)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      debug "exception in relayv2 handler", exc = exc.msg, conn
    finally:
      trace "exiting relayv2 handler", conn
      await conn.close()

  rv2.handler = handleStream
  rv2

proc start*(rv2: RelayV2) {.async.} =
  if not rv2.heartbeatFut.isNil:
    warn "Starting relayv2 twice"
    return

  rv2.heartbeatFut = rv2.heartbeat()

proc stop*(rv2: RelayV2) {.async.} =
  if rv2.heartbeatFut.isNil:
    warn "Stopping relayv2 without starting it"
    return

  rv2.heartbeatFut.cancel()

# Client side

type
  Client* = ref object of LPProtocol
    switch: Switch
    queue: AsyncQueue[Connection]
  ReserveError* = enum
    ReserveFailedDial,
    ReserveFailedConnection,
    ReserveMalformedMessage,
    ReserveBadType,
    ReserveBadStatus,
    ReserveMissingReservation,
    ReserveBadExpirationDate,
    ReserveInvalidVoucher,
    ReserveUnexpected

proc handleStopError(conn: Connection, code: RelayV2Status) {.async.} =
  trace "send stop status", status = $code & " (" & $ord(code) & ")"
  let
    msg = StopMessage(msgType: StopMessageType.Status,
      peer: none(RelayV2Peer),
      limit: none(RelayV2Limit),
      status: some(code))
    pb = encodeStopMessage(msg)

  try:
    await conn.writeLp(pb.buffer)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing error msg", exc=exc.msg, code

proc new*(T: typedesc[Client], switch: Switch): T =
  let cl = T(switch: switch)
  cl.init()
  cl

proc handleConnect(cl: Client, conn: Connection, msg: StopMessage) {.async.} =
  if msg.peer.isNone():
    await handleStopError(conn, RelayV2Status.MalformedMessage)
    return
  let src = msg.peer.get()
  var
    limitDuration: uint32
    limitData: uint64

  if msg.limit.isSome():
    limitDuration = msg.limit.get().duration
    limitData = msg.limit.get().data

  trace "incoming relay connection", src, conn

  let
    msg = StopMessage(
      msgType: StopMessageType.Status,
      peer: none(RelayV2Peer),
      limit: none(RelayV2Limit),
      status: some(RelayV2Status.Ok))
    pb = encodeStopMessage(msg)

  try:
    await conn.writeLp(pb.buffer)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing stop msg", exc=exc.msg
    return
  await cl.queue.addLast(RelayConnection.new(conn, limitDuration, limitData))
  await conn.join()

proc init*(cl: Client) =
  proc handleStream(conn: Connection, proto: string) {.async, gcsafe.} =
    try:
      let msgOpt = decodeStopMessage(await conn.readLp(MsgSize))

      if msgOpt.isNone():
        await handleHopError(conn, RelayV2Status.MalformedMessage)
        return
      else:
        trace "client handle stream", msg = msgOpt.get()
      let msg = msgOpt.get()

      if msg.msgType == StopMessageType.Connect:
        await cl.handleConnect(conn, msg)
      else:
        trace "Unexpected client / relayv2 handshake", msgType=msg.msgType
        await handleStopError(conn, RelayV2Status.MalformedMessage)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in client handler", exc = exc.msg, conn
    finally:
      trace "exiting client handler", conn
      await conn.close()

  cl.queue = newAsyncQueue[Connection](0)

  cl.handler = handleStream
  cl.codecs = @[RelayV2StopCodec]

type
  Rsvp = object
    expire: uint64           # required, Unix expiration time (UTC)
    addrs: seq[MultiAddress] # relay address for reserving peer
    voucher: Option[Voucher] # optional, reservation voucher
    limitDuration: uint32    # seconds
    limitData: uint64        # bytes
  ReservationError* = object of RelayV2Error
  RelayV2DialError* = object of RelayV2Error


proc reserve*(cl: Client, relayPI: PeerInfo): Future[Rsvp] {.async.} =
  var
    msg = HopMessage(msgType: HopMessageType.Reserve)
    msgOpt: Option[HopMessage]
  let pb = encodeHopMessage(msg)

  let conn = try:
    await cl.switch.dial(relayPI.peerId, relayPI.addrs, RelayV2HopCodec)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error opening relay stream", exc=exc.msg, relayPI
    raise newException(ReservationError, exc.msg)
  defer:
    await conn.close()

  try:
    await conn.writeLp(pb.buffer)
    msgOpt = decodeHopMessage(await conn.readLp(MsgSize))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing reservation message", exc=exc.msg
    raise newException(ReservationError, exc.msg)

  if msgOpt.isNone():
    trace "Malformed message from relay"
    raise newException(ReservationError, "Malformed message from relay")
  msg = msgOpt.get()
  if msg.msgType != HopMessageType.Status:
    trace "unexpected relay response type", msgType = msg.msgType
    raise newException(ReservationError, "Unexpected relay response type")
  if msg.status.isNone() or msg.status.get() != Ok:
    trace "reservation failed", status = msg.status
    raise newException(ReservationError, "Reservation failed")

  if msg.reservation.isNone():
    trace "missing reservation info"
    raise newException(ReservationError, "Missing reservation information")
  let reservation = msg.reservation.get()
  if now().utc > reservation.expire.int64.fromUnix.utc:
    trace "received reservation with expiration date in the past"
    raise newException(ReservationError, "Bad expiration date")
  result.expire = reservation.expire
  result.addrs = reservation.addrs

  if reservation.svoucher.isSome():
    let svoucher = SignedVoucher.decode(reservation.svoucher.get())
    if svoucher.isErr() or svoucher.get().data.relayPeerId != relayPI.peerId:
      trace "error consuming voucher envelope", error = svoucher.error
      raise newException(ReservationError, "Invalid voucher")
    result.voucher = some(svoucher.get().data)

  if msg.limit.isSome():
    result.limitDuration = msg.limit.get().duration
    result.limitData = msg.limit.get().data

proc dialPeer(
    cl: Client,
    conn: RelayConnection,
    dstPeerId: PeerID,
    dstAddrs: seq[MultiAddress]): Future[Connection] {.async.} =
  var
    msg = HopMessage(
      msgType: HopMessageType.Connect,
      peer: some(RelayV2Peer(peerId: dstPeerId, addrs: dstAddrs)))
    pb = encodeHopMessage(msg)

  trace "Dial peer", msgSend=msg

  let msgRcvFromRelayOpt = try:
    await conn.writeLp(pb.buffer)
    decodeHopMessage(await conn.readLp(MsgSize))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error reading stop response", exc=exc.msg
    raise newException(RelayV2DialError, exc.msg)

  if msgRcvFromRelayOpt.isNone():
    trace "error reading stop response", msg = msgRcvFromRelayOpt
    raise newException(RelayV2DialError, "No stop response")

  let msgRcvFromRelay = msgRcvFromRelayOpt.get()
  if msgRcvFromRelay.msgType != HopMessageType.Status:
    trace "unexcepted relay stop response", msgType = msgRcvFromRelay.msgType
    raise newException(RelayV2DialError, "Unexpected stop response")

  if msgRcvFromRelay.status.isNone() or msgRcvFromRelay.status.get() != RelayV2Status.Ok:
    trace "relay stop failure", status=msgRcvFromRelay.status
    raise newException(RelayV2DialError, "Relay stop failure")

  if msgRcvFromRelay.limit.isSome():
    conn.limitDuration = msgRcvFromRelay.limit.get().duration
    conn.limitData = msgRcvFromRelay.limit.get().data
  return conn

# Transport

type
  RelayV2Transport* = ref object of Transport
    client*: Client

method start*(self: RelayV2Transport, ma: seq[MultiAddress]) {.async.} =
  if self.running:
    trace "Relay transport already running"
    return

  await procCall Transport(self).start(ma)
  trace "Starting Relay transport"

method stop*(self: RelayV2Transport) {.async, gcsafe.} =
  self.running = false
  while not self.client.queue.empty():
    await self.client.queue.popFirstNoWait().close()

method accept*(self: RelayV2Transport): Future[Connection] {.async, gcsafe.} =
  result = await self.client.queue.popFirst()

proc dial*(self: RelayV2Transport, ma: MultiAddress): Future[Connection] {.async, gcsafe.} =
  let
    sma = toSeq(ma.items())
    relayAddrs = sma[0..sma.len-4].mapIt(it.tryGet()).foldl(a & b)
  var
    relayPeerId: PeerId
    dstPeerId: PeerId
  if not relayPeerId.init(($(sma[^3].get())).split('/')[2]):
    # raise smthg
    return
  if not dstPeerId.init(($(sma[^1].get())).split('/')[2]):
    # raise smthg
    return
  trace "Dial", relayPeerId, relayAddrs, dstPeerId

  let conn = await self.client.switch.dial(relayPeerId, @[ relayAddrs ], RelayV2HopCodec)
  let rc = RelayConnection.new(conn, 0, 0)
  result = await self.client.dialPeer(rc, dstPeerId, @[])

method dial*(
  self: RelayV2Transport,
  hostname: string,
  address: MultiAddress): Future[Connection] {.async, gcsafe.} =
  result = await self.dial(address)

const
  P2PPattern = mapEq("p2p")
  CircuitRelay = mapEq("p2p-circuit")

method handles*(self: RelayV2Transport, ma: MultiAddress): bool {.gcsafe} =
  if ma.protocols.isOk():
    let sma = toSeq(ma.items())
    if sma.len >= 3:
      result = CircuitRelay.match(sma[^2].get()) and
               P2PPattern.match(sma[^1].get())
  trace "Handles return", ma, result

proc new*(T: typedesc[RelayV2Transport], cl: Client, upgrader: Upgrade): T =
  T(client: cl, upgrader: upgrader)
