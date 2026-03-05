# Package

version       = "0.1.0"
author        = "Josh Girvin"
description   = "My attempt at a coding agent harness"
license       = "MIT"
srcDir        = "src"
bin           = @["girvent"]


# Dependencies

requires "nim >= 2.2.8"
requires "dotenv >= 2.0.0"
requires "markdown#head"
requires "noise >= 0.1.10"
requires "jsony >= 1.1.6"