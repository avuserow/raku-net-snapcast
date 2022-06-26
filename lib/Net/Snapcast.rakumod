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

Net::Snapcast - blah blah blah

=head1 SYNOPSIS

=begin code :lang<raku>

use Net::Snapcast;

=end code

=head1 DESCRIPTION

Net::Snapcast is ...

=head1 AUTHOR

Adrian Kreher <avuserow@gmail.com>

=head1 COPYRIGHT AND LICENSE

Copyright 2022 Adrian Kreher

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod
