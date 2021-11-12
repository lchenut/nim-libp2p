## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

template public {.pragma.}

type
  Switch* {.public.} = object
    field1*: int
    field2*: int
    field3: int

  PrivateStruct* = object
    hiddenField: int

proc new*(T: typedesc[Switch]): T {.public.} =
  ## Create a nice switch
  T()

proc newPrivate*(T: typedesc[Switch]): T = T()
  ## Internal procedure, don't show
