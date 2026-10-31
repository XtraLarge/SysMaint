#!/usr/bin/perl
# Gibt je BackupPC-Host die effektiv gesicherten Freigaben aus: HOST|SHARE
# Globale config.pl und Host-Datei pc/<host>.pl werden wie bei BackupPC
# zusammengefuehrt. Nur lesend. Aufruf im BackupPC-Container, z. B.:
#   ssh <nas> docker exec -i <backuppc-container> perl - /etc/backuppc < backuppc-shares.pl
use strict;
use warnings;
my $dir = shift || '/etc/backuppc';
our %Conf;
%Conf = ();
do "$dir/config.pl";
my %global = %Conf;
open(my $hf, '<', "$dir/hosts") or die "hosts: $!";
while (my $l = <$hf>) {
    next if $l =~ /^\s*(#|$)/;
    my ($host) = split /\s+/, $l;
    next if !$host || $host eq 'host';
    %Conf = %global;
    my $pc = "$dir/pc/" . lc($host) . ".pl";
    $pc = "$dir/pc/$host.pl" unless -f $pc;
    do $pc if -f $pc;
    my $method = $Conf{XferMethod} // '';
    my $shares = $method eq 'smb' ? $Conf{SmbShareName}
               : $method eq 'tar' ? $Conf{TarShareName}
               : $Conf{RsyncShareName};
    $shares = [$shares] unless ref $shares;
    print "$host|$_\n" for grep { defined && length } @$shares;
}
