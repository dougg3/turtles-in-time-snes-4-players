Boot/menu scenarios (power-on -> title -> 2P -> character select -> intro -> stage).
They are not compared frame by frame: the intro text printer runs in idle time,
so any CPU-timing change shifts later frames. `scripts/regress.sh` only
checks that each reaches gameplay with both players present.
