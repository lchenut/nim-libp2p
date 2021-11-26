In the [previous tutorial](tutorial_2_customproto.md), we dug a little deeper in to how the ping protocol works by creating a custom ping protocol ourselves.

This tutorial will focus on how to create a custom streaming protocol using libp2p.

# Custom protocol in libp2p
Let's create a `part3.nim`, and import our dependencies:
```nim
import bearssl
import chronos
import stew/byteutils

import libp2p
```
This is similar to the second tutorial. Next, we'll declare our custom protocol.
```nim
const TestStreamCodec = "/test/stream-proto/1.0.0"

type TestStreamProto = ref object of LPProtocol
```

Just as we did in the last tutorial, we've set a [protocol ID](https://docs.libp2p.io/concepts/protocols/#protocol-ids), and created a custom `LPProtocol`.

As in the last tutorial, we are going to handle our client and server parts separately. The server will wait for an instruction from the client, then send a stream of data to the client and finish by closing the connection. The client will listen in a loop until the server has finished and closed the connection. Then the client will close its end of the connection as well.

Lets start with the server part:
```nim
proc new(T: typedesc[TestStreamProto]): T =
  # every incoming connections will in be handled in this closure
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    echo "[server] received from client: ", string.fromBytes(await conn.readLp(1024))

    # send stream of data
    for i in 0..10:
      await conn.writeLp("Part " & $i)

    # We must close the connections ourselves when we're done with it
    await conn.close()

  return T(codecs: @[TestStreamCodec], handler: handle)
```
Again, `handle`, will be called for each incoming peer asking for this protocol. In our simple example, the client sends `"please send data"` and once received, the server echos the message and sends a stream of data back. In this example, we are simply sending a series of strings as the stream of data, but this can be any data in a practical application.

We can now create our client part:
```nim
proc streamData(p: TestStreamProto, conn: Connection) {.async.} =
  await conn.writeLp("please send data")
  try:
    # Read loop
    while true:
      let
        # readLp reads length prefixed bytes and returns a buffer without the prefix
        strData = await conn.readLp(1024)
        str = string.fromBytes(strData)
      echo "[client] received from server: ", str

  except LPStreamEOFError:
    # Once the remote peer has closed disconnected (closed the connection),
    # we should also close the connection from this end as well.
    # The only way to tell that a connection has been closed on the remote
    # end is to try to read the connection (readLp) and catch the
    # LPStreamEOFError that is raised when the connection is closed.
    await conn.close()
```
As a client, we want to keep reading data in a loop until the server has finished sending its stream. We will only know that the server has finished sending its stream of data when the connection has been closed. There is no data sent across the wire that signals the connection has been closed, however if we try to read data from a connection that been closed remotely, we a `LPStreamEOFError` exception will be raised. So once we catch this exception, we know the server has finished sending its stream of data, and we are safe to close the connection from the client side.

We can now create our main procedure:
```nim
proc main() {.async, gcsafe.} =
  let
    rng = newRng()
    TestStreamProto = TestStreamProto.new()
    switch1 = newStandardSwitch(rng=rng)
    switch2 = newStandardSwitch(rng=rng)

  switch1.mount(TestStreamProto)

  await switch1.start()
  await switch2.start()
  let conn = await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, TestStreamCodec)

  # conn is now a fully setup connection, we talk directly to the switch1 custom protocol handler
  await TestStreamProto.streamData(conn)

  await allFutures(switch1.stop(), switch2.stop()) # shutdown all transports
```

This is very similar to the second tutorial's `main`, except that we use our newly created stream protocol and stream codec.

We can now wrap our program by calling our main proc:
```nim
waitFor(main())
```

And that's it!
