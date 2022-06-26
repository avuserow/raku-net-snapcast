unit class Net::Snapcast;

# Just enough of a JSON RPC client over TCP for Snapcast
my class RPCClient {
    use JSON::Fast;

    has $!inputc = Channel.new;
    has $!outputc = Channel.new;
    has $!notifications = Channel.new;
    has $!conn;

    submethod BUILD(Str :$host, Int :$port) {
        $!conn = IO::Socket::Async.connect($host, $port).then(-> $promise {
            given $promise.result -> $s {
                react {
                    whenever $!inputc.Supply -> $cmd {
                        await $s.print("$cmd\n");
                    }
                    whenever $s.Supply.lines -> $v {
                        self!handle-response($v);
                    }
                    whenever $!inputc.closed {
                        done;
                    }
                    whenever $!outputc.closed {
                        done;
                    }
                }
                $s.close;
            }
        });
    }

    method !handle-response(Str $s) {
        # XXX: need error handling here
        my $data = from-json($s);

        # If there's no ID, then this is a notification
        if $data<id> {
            $!outputc.send($data);
        } else {
            $!notifications.send($data);
        }
    }

    method notifications(--> Supply) {
        return $!notifications.Supply;
    }

    method close() {
        $!inputc.close;
        await $!conn;
    }

    sub sequencer {
        state @pool = ('a' .. 'z', 'A' .. 'Z', 0 .. 9).flat;

        return @pool.roll(32).join();
    }

    method call(Str $method, $params?) {
        my %request = (
            jsonrpc => '2.0',
            method => $method,
            id => sequencer(),
        );

        %request<params> = $_ with $params;

        $!inputc.send(to-json(%request, :!pretty));
        my $resp = $!outputc.receive;
        return $resp<result>;
    }
}

# Represents a snapcast client
class Client {
    has Str $.id is readonly;
    has Str $.name is readonly;
    has Int $.instance is readonly;

    has Str $.hostname is readonly;
    has Str $.os is readonly;
    has Str $.ip is readonly;
    has Str $.arch is readonly;
    has Str $.mac is readonly;

    has Bool $.connected is readonly;

    has Bool $.muted is rw;
    has Int $.volume is rw;

    # XXX: these should be a container object maybe?
    has Str $.group-id is rw;
    has Str $.stream-id is rw;

    submethod BUILD(:$client, :$stream-id, :$group-id) {
        $!arch = $client<host><arch>;
        $!ip = $client<host><ip>;
        $!mac = $client<host><mac>;
        $!hostname = $client<host><name>;
        $!os = $client<host><os>;

        $!id = $client<id>;
        $!connected = $client<connected>;

        $!name = $client<config><name> || $!hostname;
        $!instance = $client<config><instance>;
        $!volume = $client<config><volume><percent>;
        $!muted = $client<config><volume><muted>;

        $!stream-id = $stream-id;
        $!group-id = $group-id;
    }
}

has $!client;

has %!clients;
has $.callback is rw;

submethod BUILD(Str :$host, Int :$port) {
    $!client = RPCClient.new(:$host, :$port);
    self.sync;
}

method !setup-notifications {
    $!client.notifications.tap(-> $e {
        given $e<method> {
            when 'Client.OnVolumeChanged' {
                self!handle-client-volume-change($e<params>);
            }
            when 'Client.OnConnect' {
                # just re-sync here, since we really want to know what stream it belongs to
                self.sync;
            }
            when 'Client.OnDisconnect' {
                self!handle-client-disconnect($e<params>);
            }
            when 'Group.OnStreamChanged' {
                # need to model groups before we can handle this fully
                self.sync;
            }
            when 'Server.OnUpdate' {
                # unsure what this could mean, so just resync
                self.sync;
            }
            default {
                say "method $e<method> NYI!";
            }
        }

        if $.callback {
            dd $e<method>, $e<params>;
            $.callback.($e<method>, $e<params>);
            CATCH {
                default {
                    .say;
                }
            }
        }
    });
}

method !handle-client-disconnect($params) {
    %!clients{$params<id>}:delete;
}

method !handle-client-volume-change($params) {
    unless %!clients{$params<id>} {
        note "no such client $params<id>";
        return;
    }

    # say "updating volume for $params<id>: $params<volume><percent>, $params<volume><muted>, $params.raku()";
    %!clients{$params<id>}.volume = $params<volume><percent>;
    %!clients{$params<id>}.muted = $params<volume><muted>;
}

method sync {
    my $resp = $!client.call('Server.GetStatus');

    self!setup-notifications;

    %!clients = ();
    for $resp<server><groups>.list -> $group {
        my $group-id = $group<id>;
        my $stream-id = $group<stream_id>;
        for $group<clients>.list {
            %!clients{$_<id>} = Client.new(:client($_), :$stream-id, :$group-id);
        }
    }
}

method list-clients {
    %!clients.values.sort(*.name);
}

method set-volume(Str $client-id, Int $volume) {
    # say "set-volume: $client-id to $volume";
    my $resp = $!client.call('Client.SetVolume', {
        id => $client-id,
        volume => {
            percent => $volume,
        },
    });
    self!handle-client-volume-change({id => $client-id, |$resp});
}

=begin pod

=head1 NAME

Net::Snapcast - Control Snapcast audio players

=head1 SYNOPSIS

=begin code :lang<raku>

use Net::Snapcast;

my $sc = Net::Snapcast.new(:$host, :port(1705));

# list clients attached to snapcast
my @clients = $sc.list-clients;

# change volume on a client
$sc.set-volume(@clients[0].id, 100);

# listen for events (from other clients only)
# interface will be changed!
$sc.callback = sub ($method, $params) {dd $method, $params};

=end code

=head1 DESCRIPTION

Net::Snapcast is an interface for controlling players connected to a Snapcast server. Snapcast is a client/server system for building a multiroom audio system. The server consumes audio from one or more sources, controls which client receives which audio stream, and manages latency to keep audio playback synchronized. See L<https://github.com/badaix/snapcast> for more details on Snapcast.

This module implements the control interface to Snapcast, allowing you to manage the various players. You can programmatically control what client is connected to which stream, change the volume, and receive notifications of changes made by other clients.

This module does not implement any audio sending or receiving. In snapcast terms, this implements the "Control API" (on port 1705 by default).

=head1 METHODS

=head2 new(:$host, :$port)

Connects to the given Snapcast server and synchronizes the state.

=head2 list-clients

Returns a list of clients. See the C<Net::Snapcast::Snapclient> class below for the included attributes.

=head2 set-volume($id, $volume)

Sets the volume level of the provided client.

=head2 sync

Re-sync cached snapcast data. This is called automatically as needed and should not need to be invoked manually.

=head1 SUBCLASSES

=head2 Snapclient - details about a connected client

This class is returned from C<list-clients>. This is called "snapclient" after the snapcast player command's name. All attributes should be considered read-only.

=head3 Client Attributes

=item Str id - snapcast-assigned client ID, defaults to MAC address with optional instance ID
=item Str name - configured client name, as set by the snapcast API C<Client.SetName>. Defaults to hostname if unset, and there may be duplicate client names.
=item Int instance - instance ID of the snapcast clients. Defaults to 1 and only changed when running multiple clients per computer
=item Str hostname - hostname of the computer running this client
=item Str os - operating system of this client
=item Str ip - IP address of this client
=item Str arch - architecture of this client (e.g. C<x86_64>, C<armv6l>, C<arm64-v8a>)
=item Str mac - MAC address of this client, if available (otherwise may be all zeroes)
=item Bool connected - indicates whether this client is currently connected to snapcast (or if the server just remembers this client). You can still modify attributes of disconnected clients, but they disappear upon server restart.
=item Bool muted - indicates whether this client is muted in snapcast
=item Int volume - indicates volume level within snapcast
=item Str group-id - ID of the group containing this client (NOTE: group APIs are not yet implemented)
=item Str stream-id - ID of the audio stream that this client is consuming (actually the "name" of the stream in snapcast config)

=head1 SEE ALSO

L<https://github.com/badaix/snapcast> - snapcast repo

L<https://github.com/badaix/snapcast/blob/master/doc/json_rpc_api/control.md> - documentation for control protocol

=head1 AUTHOR

Adrian Kreher <avuserow@gmail.com>

=head1 COPYRIGHT AND LICENSE

Copyright 2022 Adrian Kreher

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod
