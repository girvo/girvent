Nim code that has sequential let/const/var calls like so:
```nim
let one = two
let three = four
let five = six
```
should instead be formatted as
```nim
let
  one = two
  three = four
  five = six
```