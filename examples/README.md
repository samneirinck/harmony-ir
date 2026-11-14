# LG power examples

These files contain illustrative LG discrete power commands at 38000 Hz. They
are not a universal LG device database or a guarantee of appliance compatibility.

- `lg-power-on.txt`: `20DF23DC` (Power On).
- `lg-power-off.txt`: `20DFA35C` (Power Off).

Each file contains signed microsecond timings: positive marks and negative
spaces. The keycode is expanded most-significant-bit first, followed by a fixed
repeat frame. Combined duration is 215735 µs; the transmitter defaults to 33% duty.

For preparing and sending a request through the running bridge, see the
[API example](../API.md#controlled-lg-power-check). Only send a command when
ready to operate the appliance. Do not chain On and Off as a test or retry an
uncertain transmission automatically.
