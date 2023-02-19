[![Actions Status](https://github.com/avuserow/raku-net-snapcast/actions/workflows/test.yml/badge.svg)](https://github.com/avuserow/raku-net-snapcast/actions)

NAME
====

Net::Snapcast - Control Snapcast audio players

SYNOPSIS
========

```raku
use Net::Snapcast;

my $sc = Net::Snapcast.new(:$host, :port(1705));

# list clients attached to snapcast
my @clients = $sc.list-clients;

# change volume on a client
$sc.set-volume(@clients[0].id, 100);

# get a supply of events (from other clients only)
# see documentation at https://github.com/badaix/snapcast/blob/master/doc/json_rpc_api/control.md#notifications
$sc.notifications.tap(-> $e {
    say "event type $e<method>: $e<params>";
})
```

DESCRIPTION
===========

Net::Snapcast is an interface for controlling players connected to a Snapcast server. Snapcast is a client/server system for building a multiroom audio system. The server consumes audio from one or more sources, controls which client receives which audio stream, and manages latency to keep audio playback synchronized. See [https://github.com/badaix/snapcast](https://github.com/badaix/snapcast) for more details on Snapcast.

This module implements the control interface to Snapcast, allowing you to manage the various players. You can programmatically control what client is connected to which stream, change the volume, and receive notifications of changes made by other clients.

This module does not implement any audio sending or receiving. In snapcast terms, this implements the "Control API" (on port 1705 by default).

This module is currently tested with a Snapcast server running 0.25.0.

METHODS
=======

new(:$host, :$port)
-------------------

Connects to the given Snapcast server and synchronizes the state.

sync
----

Re-sync cached snapcast data. This is called automatically as needed and should not need to be invoked manually.

notifications
-------------

Returns a Supply that receives events from other clients. If this client makes an RPC call (e.g. `set-volume`), then this Supply will not receive an event.

Events are documented at [https://github.com/badaix/snapcast/blob/master/doc/json_rpc_api/control.md#notifications](https://github.com/badaix/snapcast/blob/master/doc/json_rpc_api/control.md#notifications) and may vary depending on the Snapcast server.

list-clients
------------

Returns a list of clients. See the `Net::Snapcast::Snapclient` class below for the included attributes.

set-volume($id, Int $volume?, Bool :$muted)
-------------------------------------------

Sets the volume level of the provided client and/or changes the mute status. You can pass either volume, mute, or both.

SUBCLASSES
==========

Snapclient - details about a connected client
---------------------------------------------

This class is returned from `list-clients`. This is called "snapclient" after the snapcast player command's name. All attributes should be considered read-only.

### Client Attributes

  * Str id - snapcast-assigned client ID, defaults to MAC address with optional instance ID

  * Str name - configured client name, as set by the snapcast API `Client.SetName`. Defaults to hostname if unset, and there may be duplicate client names.

  * Int instance - instance ID of the snapcast clients. Defaults to 1 and only changed when running multiple clients per computer

  * Str hostname - hostname of the computer running this client

  * Str os - operating system of this client

  * Str ip - IP address of this client

  * Str arch - architecture of this client (e.g. `x86_64`, `armv6l`, `arm64-v8a`)

  * Str mac - MAC address of this client, if available (otherwise may be all zeroes)

  * Bool connected - indicates whether this client is currently connected to snapcast (or if the server just remembers this client). You can still modify attributes of disconnected clients, but they disappear upon server restart.

  * Bool muted - indicates whether this client is muted in snapcast

  * Int volume - indicates volume level within snapcast

  * Str group-id - ID of the group containing this client (NOTE: group APIs are not yet implemented)

  * Str stream-id - ID of the audio stream that this client is consuming (actually the "name" of the stream in snapcast config)

SEE ALSO
========

[https://github.com/badaix/snapcast](https://github.com/badaix/snapcast) - snapcast repo

[https://github.com/badaix/snapcast/blob/master/doc/json_rpc_api/control.md](https://github.com/badaix/snapcast/blob/master/doc/json_rpc_api/control.md) - documentation for control protocol

AUTHOR
======

Adrian Kreher <avuserow@gmail.com>

COPYRIGHT AND LICENSE
=====================

Copyright 2022 Adrian Kreher

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

