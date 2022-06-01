{.used.}

import bearssl, chronos, options
import ../libp2p
import ../libp2p/[protocols/relay/relay,
                  protocols/relay/messages,
                  protocols/relay/utils,
                  protocols/relay/client]
import ./helpers
import std/times
import stew/byteutils

proc createSwitch(cl: RelayClient): Switch =
  result = SwitchBuilder.new()
    .withRng(newRng())
    .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .withCircuitRelayTransport(cl)
    .build()

suite "Circuit Relay V2":

  suite "Reservation":
    asyncTearDown:
      await allFutures(src1.stop(), src2.stop(), rel.stop())
      checkTrackers()
    var
      ttl {.threadvar.}: int
      ldur {.threadvar.}: uint32
      ldata {.threadvar.}: uint64
      cl1 {.threadvar.}: RelayClient
      cl2 {.threadvar.}: RelayClient
      rv2 {.threadvar.}: Relay
      src1 {.threadvar.}: Switch
      src2 {.threadvar.}: Switch
      rel {.threadvar.}: Switch
      rsvp {.threadvar.}: Rsvp
      range {.threadvar.}: HSlice[times.DateTime, times.DateTime]

    asyncSetup:
      ttl = 1
      ldur = 60
      ldata = 2048
      cl1 = RelayClient.new()
      cl2 = RelayClient.new()
      src1 = createSwitch(cl1)
      src2 = createSwitch(cl2)
      rel = newStandardSwitch()
      rv2 = Relay.new(rel,
                        reservationTTL=initDuration(seconds=ttl),
                        limitDuration=ldur,
                        limitData=ldata,
                        maxCircuit=1)
      rel.mount(rv2)
      await rv2.start()
      await src1.start()
      await src2.start()
      await rel.start()
      await src1.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
      await src2.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
      rsvp = await cl1.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)
      range = now().utc + (ttl-1).seconds..now().utc + (ttl+1).seconds
      check:
        rsvp.expire.int64.fromUnix.utc in range
        rsvp.limitDuration == ldur
        rsvp.limitData == ldata

    asynctest "Too many reservations":
      let conn = await cl2.switch.dial(rel.peerInfo.peerId, rel.peerInfo.addrs, RelayV2HopCodec)
      let pb = encode(HopMessage(msgType: HopMessageType.Reserve))
      await conn.writeLp(pb.buffer)
      let msg = HopMessage.decode(await conn.readLp(MsgSize)).get()
      check:
        msg.msgType == HopMessageType.Status
        msg.status == some(StatusV2.ReservationRefused)

    asynctest "Too many reservations + Reconnect":
      expect(ReservationError):
        discard await cl2.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)
      await rel.disconnect(src1.peerInfo.peerId)
      rsvp = await cl2.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)
      range = now().utc + (ttl-1).seconds..now().utc + (ttl+1).seconds
      check:
        rsvp.expire.int64.fromUnix.utc in range
        rsvp.limitDuration == ldur
        rsvp.limitData == ldata

    asynctest "Reservation ttl expires":
      await sleepAsync(chronos.timer.seconds(ttl + 1))
      rsvp = await cl1.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)
      range = now().utc + (ttl-1).seconds..now().utc + (ttl+1).seconds
      check:
        rsvp.expire.int64.fromUnix.utc in range
        rsvp.limitDuration == ldur
        rsvp.limitData == ldata

    asynctest "Reservation over relay":
      let
        rv2add = Relay.new(src2)
        addrs = @[ MultiAddress.init($rel.peerInfo.addrs[0] & "/p2p/" &
                                     $rel.peerInfo.peerId & "/p2p-circuit/p2p/" &
                                     $src2.peerInfo.peerId).get() ]
      src2.mount(rv2add)
      await rv2add.start()
      rv2.maxCircuit.inc()

      rsvp = await cl2.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)
      range = now().utc + (ttl-1).seconds..now().utc + (ttl+1).seconds
      check:
        rsvp.expire.int64.fromUnix.utc in range
        rsvp.limitDuration == ldur
        rsvp.limitData == ldata
      expect(ReservationError):
        discard await cl1.reserve(src2.peerInfo.peerId, addrs)

  suite "Connection":
    asyncTearDown:
      await allFutures(src.stop(), dst.stop(), rel.stop())
      checkTrackers()
    var
      addrs {.threadvar.}: MultiAddress
      customProtoCodec {.threadvar.}: string
      proto {.threadvar.}: LPProtocol
      ttl {.threadvar.}: int
      ldur {.threadvar.}: uint32
      ldata {.threadvar.}: uint64
      srcCl {.threadvar.}: RelayClient
      dstCl {.threadvar.}: RelayClient
      rv2 {.threadvar.}: Relay
      src {.threadvar.}: Switch
      dst {.threadvar.}: Switch
      rel {.threadvar.}: Switch
      rsvp {.threadvar.}: Rsvp
      conn {.threadvar.}: Connection

    asyncSetup:
      customProtoCodec = "/test"
      proto = new LPProtocol
      proto.codec = customProtoCodec
      ttl = 60
      ldur = 120
      ldata = 16384
      srcCl = RelayClient.new()
      dstCl = RelayClient.new()
      src = createSwitch(srcCl)
      dst = createSwitch(dstCl)
      rel = newStandardSwitch()
      addrs = MultiAddress.init($rel.peerInfo.addrs[0] & "/p2p/" &
                                $rel.peerInfo.peerId & "/p2p-circuit/p2p/" &
                                $dst.peerInfo.peerId).get()

    asynctest "Connection succeed":
      proto.handler = proc(conn: Connection, proto: string) {.async.} =
        check: "test1" == string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("test2")
        check: "test3" == string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("test4")
        await conn.close()
      rv2 = Relay.new(rel,
                        reservationTTL=initDuration(seconds=ttl),
                        limitDuration=ldur,
                        limitData=ldata)
      rel.mount(rv2)
      dst.mount(proto)

      await rv2.start()
      await rel.start()
      await src.start()
      await dst.start()

      await src.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
      await dst.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)

      rsvp = await dstCl.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)

      conn = await src.dial(dst.peerInfo.peerId, @[ addrs ], customProtoCodec)
      await conn.writeLp("test1")
      check: "test2" == string.fromBytes(await conn.readLp(1024))
      await conn.writeLp("test3")
      check: "test4" == string.fromBytes(await conn.readLp(1024))
      await conn.close()

    asynctest "Connection duration exceeded":
      ldur = 2
      proto.handler = proc(conn: Connection, proto: string) {.async.} =
        check "wanna sleep?" == string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("yeah!")
        check "go!" == string.fromBytes(await conn.readLp(1024))
        await sleepAsync(3000)
        await conn.writeLp("that was a cool power nap")
        await conn.close()
      rv2 = Relay.new(rel,
                        reservationTTL=initDuration(seconds=ttl),
                        limitDuration=ldur,
                        limitData=ldata)
      rel.mount(rv2)
      dst.mount(proto)

      await rv2.start()
      await rel.start()
      await src.start()
      await dst.start()

      await src.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
      await dst.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)

      rsvp = await dstCl.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)
      conn = await src.dial(dst.peerInfo.peerId, @[ addrs ], customProtoCodec)
      await conn.writeLp("wanna sleep?")
      check: "yeah!" == string.fromBytes(await conn.readLp(1024))
      await conn.writeLp("go!")
      expect(LPStreamEOFError):
        discard await conn.readLp(1024)

    asynctest "Connection data exceeded":
      ldata = 1000
      proto.handler = proc(conn: Connection, proto: string) {.async.} =
        check "count me the better story you know" == string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("do you expect a lorem ipsum or...?")
        check "surprise me!" == string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("""Call me Ishmael. Some years ago--never mind how long
precisely--having little or no money in my purse, and nothing
particular to interest me on shore, I thought I would sail about a
little and see the watery part of the world. It is a way I have of
driving off the spleen and regulating the circulation. Whenever I
find myself growing grim about the mouth; whenever it is a damp,
drizzly November in my soul; whenever I find myself involuntarily
pausing before coffin warehouses, and bringing up the rear of every
funeral I meet; and especially whenever my hypos get such an upper
hand of me, that it requires a strong moral principle to prevent me
from deliberately stepping into the street, and methodically knocking
people's hats off--then, I account it high time to get to sea as soon
as I can. This is my substitute for pistol and ball. With a
philosophical flourish Cato throws himself upon his sword; I quietly
take to the ship.""")
      rv2 = Relay.new(rel,
                        reservationTTL=initDuration(seconds=ttl),
                        limitDuration=ldur,
                        limitData=ldata)
      rel.mount(rv2)
      dst.mount(proto)

      await rv2.start()
      await rel.start()
      await src.start()
      await dst.start()

      await src.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
      await dst.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)

      rsvp = await dstCl.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)
      conn = await src.dial(dst.peerInfo.peerId, @[ addrs ], customProtoCodec)
      await conn.writeLp("count me the better story you know")
      check: "do you expect a lorem ipsum or...?" == string.fromBytes(await conn.readLp(1024))
      await conn.writeLp("surprise me!")
      expect(LPStreamEOFError):
        discard await conn.readLp(1024)

    asynctest "Reservation ttl expire during connection":
      ttl = 1
      proto.handler = proc(conn: Connection, proto: string) {.async.} =
        check: "test1" == string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("test2")
        check: "test3" == string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("test4")
        await conn.close()
      rv2 = Relay.new(rel,
                        reservationTTL=initDuration(seconds=ttl),
                        limitDuration=ldur,
                        limitData=ldata)
      rel.mount(rv2)
      dst.mount(proto)

      await rv2.start()
      await rel.start()
      await src.start()
      await dst.start()

      await src.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
      await dst.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)

      rsvp = await dstCl.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)
      conn = await src.dial(dst.peerInfo.peerId, @[ addrs ], customProtoCodec)
      await conn.writeLp("test1")
      check: "test2" == string.fromBytes(await conn.readLp(1024))
      await conn.writeLp("test3")
      check: "test4" == string.fromBytes(await conn.readLp(1024))
      await src.disconnect(rel.peerInfo.peerId)
      await sleepAsync(2000)

      expect(DialFailedError):
        check: conn.atEof()
        await conn.close()
        await src.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
        conn = await src.dial(dst.peerInfo.peerId, @[ addrs ], customProtoCodec)

    asynctest "Connection over relay":
      # src => rel => rel2 => dst
      # rel2 reserve rel
      # dst reserve rel2
      # src try to connect with dst
      proto.handler = proc(conn: Connection, proto: string) {.async.} =
        raise newException(CatchableError, "Should not be here")
      let
        rel2Cl = RelayClient.new()
        rel2 = createSwitch(rel2Cl)
        rv2 = Relay.new(rel)
        rv2add = Relay.new(rel2)
        addrs = @[ MultiAddress.init($rel.peerInfo.addrs[0] & "/p2p/" &
                                     $rel.peerInfo.peerId & "/p2p-circuit/p2p/" &
                                     $rel2.peerInfo.peerId & "/p2p/" &
                                     $rel2.peerInfo.peerId & "/p2p-circuit/p2p/" &
                                     $dst.peerInfo.peerId).get() ]
      rel.mount(rv2)
      dst.mount(proto)
      rel2.mount(rv2add)
      await rv2.start()
      await rv2add.start()
      await rel.start()
      await rel2.start()
      await src.start()
      await dst.start()

      await src.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
      await rel2.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
      await dst.connect(rel2.peerInfo.peerId, rel2.peerInfo.addrs)

      rsvp = await rel2Cl.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)
      let rsvp2 = await dstCl.reserve(rel2.peerInfo.peerId, rel2.peerInfo.addrs)

      expect(DialFailedError):
        conn = await src.dial(dst.peerInfo.peerId, addrs, customProtoCodec)
      await rel2.stop()
