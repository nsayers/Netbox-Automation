package XenConfig;

use strict;
use warnings;

our %CONFIG = (
    xenservers => {
        cluster1 => {
            url         => "http://cluster1.example.com",
            domainname  => "example.com",
            xenuser     => 'root',
            xenpass     => 'pass',
            xenversion  => '8.1', # XCP-ng
            cluster     => '8',
            site        => '2',
        },
        cluster2 => {
            url         => "http://cluster2.example.com",
            domainname  => "example.com",
            xenuser     => 'root',
            xenpass     => 'pass',
            xenversion  => '6.5', # xenserver 6.5
            cluster     => '14',
            site        => '1',
        },
    },
    netbox_api_url  => "https://netbox.example.com/api/",
    netbox_token    => '{netbox_token}',
);

sub get {
    my ($key) = @_;
    return $CONFIG{$key};
}

sub get_xenserver {
    my ($name) = @_;
    my %server_info = (%{ $CONFIG{xenservers}{$name} }, netbox_api_url => $CONFIG{netbox_api_url}, netbox_token => $CONFIG{netbox_token});
    return \%server_info;
}

1;