LanScreen for Windows 7 (64-bit) -- phase 0
===========================================

This is a test client. It shows the Mac's screen on this iMac under Windows 7,
decoded in hardware, and reports how well that works back to the Mac. It does
not yet draw its own pointer (the Mac puts the pointer in the picture instead),
play sound, or send this keyboard and mouse to the Mac.

Windows 7 no longer gets security fixes. Keep this PC on the cable to the Mac.


Setting up, once
----------------

1. The cable's address. Control Panel > Network and Sharing Center > Change
   adapter settings > the Ethernet adapter on the cable > Properties >
   Internet Protocol Version 4 > Use the following IP address:
       IP address   10.0.0.2
       Subnet mask  255.255.255.0
   Leave the gateway and DNS empty. This is the same address the iMac has
   under OS X; the Mac sends the picture to it.

2. The firewall. The first time, run.cmd asks Windows for permission to add a
   single rule: UDP port 5000, from 10.0.0.1 only, for lanscreen.exe only.


Using it
--------

Double-click run.cmd rather than lanscreen.exe: it sets up the firewall rule
the first time and checks the address. Start streaming on the Mac from LanScreen in the menu
bar, if it is not already. Esc quits.

  run.cmd -windowed        a borderless window instead of exclusive fullscreen
  run.cmd -host 10.0.0.1   if the Mac is somewhere else


What to look at
---------------

On the Mac, LanScreen's menu bar panel, as for the OS X client:
  Decoder       hardware or software. Hardware is the point of all this.
  Decode        milliseconds per picture.
  Render        milliseconds to convert and present one.
  Glass to glass  the estimate of the whole delay.
  A colour warning, if this graphics driver does not convert as asked.

Here, lanscreen.log beside lanscreen.exe: the graphics card and driver, whether
decoding is in hardware, the colour check, and a line every ten seconds with
frames, packets and timings. Send that file back if anything looks wrong.
