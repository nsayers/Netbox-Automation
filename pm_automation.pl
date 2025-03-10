#!/usr/bin/perl
#
# written by Neil Sayers
#
# debug is simple, should give you all the details that are making it into the netbox instance.
# ./px-ind_automation.pl --debug

####### Setting up a new cluster
#
# Log into the proxmox interface, 
# Go to Datacenter -> Permissions -> Roles
# Add new role as "Automation" to include Mapping.Audit, VM.Audit, Sys.Audit, Datastore.Audit, SDN.Audit, VM.Monitor, Pool.Audit
# 
# Go to Datacenter -> Permissions -> API Token
# Add new token, username root@pam with token name of "Automation" and expiration if policy states.  Token name can be changed, see $proxmox_token_id below.
#
# Go to Datacenter -> Permissions
# Add API Token permissions, to not have to put multiple lines leave under /
# assign the token, root@pam!Automation or whatever you setup before
# assign role Automation, and allow propagate.
#
# Create the cluster in netbox under Virtualization -> Cluster, name whatever but recommend using the Cluster name.
#
#
# DONT FORGET TO UPDATE THE CLUSTER AND SITE DETAILS below with what is generated from netbox
####


use strict;
use warnings;
use LWP::UserAgent;
use JSON;
use IO::Socket::SSL;
use Data::Dumper;
use Getopt::Long;

my $proxmox_api_url = 'https://px1.example.com:8006/api2/';
my $proxmox_api_nodes = 'json/nodes';
my $proxmox_token_id = 'root@pam%21Automation';
my $proxmox_token_secret = '{PROXMOX TOKEN}';

my $netbox_api_url = "https://netbox.example.com/api/";
my $netbox_device_url = "dcim/devices/";
my $netbox_virtualization_url = "virtualization/virtual-machines/";
my $netbox_token = '{NETBOX TOKEN}';

my $cluster = '13';  # Set this to the cluster ID from Netbox
my $site = '15';  # Set this to the site of the cluster in Netbox
my $debug = 0;

GetOptions('debug' => \$debug) or die "Invalid options\n";

print "Indiana cluster automation ran at " . localtime . "\n";

my $ua = LWP::UserAgent->new;
$ua->ssl_opts(verify_hostname => 0, SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE);
$ua->default_header('Authorization' => "PVEAPIToken=$proxmox_token_id=$proxmox_token_secret");

my $netbox_ua = LWP::UserAgent->new;
$netbox_ua->default_header('Authorization' => "Token $netbox_token");

# curl -k -X GET 'https://10.180.22.39:8006/api2/json/nodes/' -H 'Authorization: PVEAPIToken=root@pam%21Automation=04013524-cce3-4038-816d-f715e5d89fe3'

my $response = $ua->get($proxmox_api_url . $proxmox_api_nodes);
die "Failed to get node data: ", $response->status_line unless $response->is_success;
my $nodes_data = decode_json($response->decoded_content);

my %proxmox_vms;

if($debug) { print "Checking for nodes in netbox\n"; }
foreach my $node (@{$nodes_data->{data}}) {
    my $node_name = $node->{node};
        proxmox_node($node_name,$cluster,$site,'active',$proxmox_api_url,$ua,$netbox_api_url,$netbox_ua);

    # curl -k -X GET 'https://10.180.22.39:8006/api2/json/nodes/pm2/qemu' -H 'Authorization: PVEAPIToken=root@pam%21Automation=04013524-cce3-4038-816d-f715e5d89fe3'

    my $qemu_response = $ua->get("$proxmox_api_url/json/nodes/$node_name/qemu");
    die "Failed to get QEMU data for node $node_name: ", $qemu_response->status_line unless $qemu_response->is_success;
    my $qemu_data = decode_json($qemu_response->decoded_content);

    my $lxc_response = $ua->get("$proxmox_api_url/json/nodes/$node_name/lxc");
    die "Failed to get LXC data for node $node_name: ", $lxc_response->status_line unless $lxc_response->is_success;
    my $lxc_data = decode_json($lxc_response->decoded_content);

    foreach my $vm (@{$qemu_data->{data}}, @{$lxc_data->{data}}) {
        my $mem_mb = sprintf("%.2f", $vm->{maxmem} / (1024 * 1024));

        my $type = (exists $vm->{type} && $vm->{type} eq 'lxc') ? 'lxc' : 'qemu';

        $proxmox_vms{$vm->{name}} = {
            name     => $vm->{name},
            status   => ($vm->{status} eq 'running') ? 'active' : 'offline',
            vcpus    => $vm->{cpus},
            memory   => $mem_mb,
            vmid     => $vm->{vmid},
            node     => $node->{node},
            type     => $type,
        };
    }
}

my $netbox_response = $netbox_ua->get("$netbox_api_url$netbox_virtualization_url?cluster_id=$cluster&limit=1000");
die "Failed to get NetBox VM data: ", $netbox_response->status_line unless $netbox_response->is_success;
my $netbox_data = decode_json($netbox_response->decoded_content);

my %netbox_vms;
foreach my $vm (@{$netbox_data->{results}}) {
    $netbox_vms{$vm->{name}} = {
        id      => $vm->{id},  # ID for updates
        name    => $vm->{name},
        status  => $vm->{status}{label}, # NetBox uses nested status
        vcpus   => $vm->{vcpus},
        memory  => $vm->{memory},
    };
}

foreach my $vm_name (keys %proxmox_vms) {
    if($debug) { print "Checking for $vm_name in netbox ....\n"; }
    if (exists $netbox_vms{$vm_name}) {
        # Compare attributes to see if update is needed
        my $needs_update = 0;
        my $netbox_vm = $netbox_vms{$vm_name};
        my $proxmox_vm = $proxmox_vms{$vm_name};
        my $proxmox_vmid = $proxmox_vms{$vm_name}->{vmid};
        my $type = $proxmox_vms{$vm_name}->{type};


        foreach my $key (qw(status vcpus memory)) {
            if ($key eq 'status') {
                if (lc($netbox_vm->{$key}) ne lc($proxmox_vm->{$key})) {
                    $needs_update = 1;

                    if($debug) { 
                        print "\tDifference found for VM $vm_name:\n";
                        print "\t  $key: NetBox = $netbox_vm->{$key}, Proxmox = $proxmox_vm->{$key}\n";
                    }
                }
            } elsif ($key eq 'memory') {
                # Convert memory to integer (removing decimal places)
                my $netbox_memory = int($netbox_vm->{$key});
                my $proxmox_memory = sprintf("%.0f", $proxmox_vm->{$key}); # Round Proxmox memory to integer

                if ($netbox_memory != $proxmox_memory) {
                    $needs_update = 1;

                    if($debug) { 
                        print "Difference found for VM $vm_name:\n";
                        print "\t  $key: NetBox = $netbox_memory, Proxmox = $proxmox_memory\n";
                    }
                }
            } else {
                if ($netbox_vm->{$key} ne $proxmox_vm->{$key}) {
                    $needs_update = 1;

                    if($debug) { 
                        print "\tDifference found for VM $vm_name:\n";
                        print "\t  $key: NetBox = $netbox_vm->{$key}, Proxmox = $proxmox_vm->{$key}\n";
                    }
                }
            }
        }

        if ($needs_update) {
            print "\tUpdating VM $vm_name in NetBox...\n";

            my $update_payload = {
                name    => $vm_name,
                cluster => $cluster,
                status  => $proxmox_vm->{status},
                vcpus   => $proxmox_vm->{vcpus},
                memory  => $proxmox_vm->{memory},
            };
            my $json_payload = encode_json($update_payload);
            my $update_response = $netbox_ua->put("$netbox_api_url$netbox_virtualization_url$netbox_vm->{id}/",
                'Content-Type' => 'application/json',
                Content => $json_payload
            );

            if ($update_response->is_success) {
                if($debug) { print "Updated VM $vm_name in NetBox.\n"; }
            } else {
                warn "Failed to update VM $vm_name: ", $update_response->status_line, "\n";
                print "curl -X PUT '$netbox_api_url$netbox_virtualization_url$netbox_vms{$vm_name}->{id}/' ";
                print "-H 'Authorization: Token $netbox_token' ";
                print "-H 'Content-Type: application/json' ";
                print "-d '" . encode_json({ name => $vm_name, cluster => $cluster, status => $proxmox_vm->{status} }) . "'\n";
            }
        }

        my $proxmox_node = $proxmox_vm->{node};
        my $netbox_id = $netbox_vm->{id};
        if($type eq 'qemu') {
            kvm_import_netbox($proxmox_vmid,$proxmox_api_url,$proxmox_token_id,$proxmox_token_secret,$proxmox_node,$netbox_api_url,$netbox_token,$netbox_id);
        } elsif($type eq 'lxc') {
            lxc_import_netbox($proxmox_vmid,$proxmox_api_url,$proxmox_token_id,$proxmox_token_secret,$proxmox_node,$netbox_api_url,$netbox_token,$netbox_id);
        }

    } else {
        if($debug) { print "\tAdding VM $vm_name to NetBox...\n"; }

        my $insert_payload = {
            name    => $proxmox_vms{$vm_name}->{name},
            status  => $proxmox_vms{$vm_name}->{status},
            site    => $site,
            cluster => $cluster,
            vcpus   => $proxmox_vms{$vm_name}->{vcpus},
            memory  => $proxmox_vms{$vm_name}->{memory},
            description => "Proxmox VM ID: " . $proxmox_vms{$vm_name}->{vmid},
        };

        my $json_payload = encode_json($insert_payload);
        my $post_response = $netbox_ua->post("$netbox_api_url$netbox_virtualization_url",
            'Content-Type' => 'application/json',
            Content => $json_payload
        );

        if ($post_response->is_success) {
            if($debug) { print "\t\tAdded VM $vm_name to NetBox.\n"; }
        } else {
            warn "Failed to add VM $vm_name: ", $post_response->status_line, "\n";
        }
    }

}

foreach my $vm_name (keys %netbox_vms) {
    unless (exists $proxmox_vms{$vm_name}) {
        if($debug) { print "\tVM $vm_name exists in NetBox but not in Proxmox. Marking as decommissioning...\n"; }

        my $json_payload = encode_json({ name => $vm_name, cluster => $cluster, status => "decommissioning" });
        my $update_response = $netbox_ua->put("$netbox_api_url$netbox_virtualization_url$netbox_vms{$vm_name}->{id}/",
            'Content-Type' => 'application/json',
            Content => $json_payload
        );

        if ($update_response->is_success) {
            if($debug) { print "\t\tMarked $vm_name as decommissioning in NetBox.\n"; }
        } else {
            warn "Failed to update status for $vm_name: ", $update_response->status_line, "\n";
            print "curl -X PUT '$netbox_api_url$netbox_virtualization_url$netbox_vms{$vm_name}->{id}/' ";
            print "-H 'Authorization: Token $netbox_token' ";
            print "-H 'Content-Type: application/json' ";
            print "-d '" . encode_json({ name => $vm_name, cluster => $cluster, status => "decommissioning" }) . "'\n";
        }
    }
}


sub kvm_import_netbox {
    my ($vm_id, $proxmox_api_url, $proxmox_token_id, $proxmox_token_secret, $proxmox_node, $netbox_api_url, $netbox_token, $netbox_id) = @_;
    if($debug) { print "Checking Virtual server in netbox\n"; }
    if($debug) {  print "VM ID : $vm_id, Node : $proxmox_node, Netbox ID : $netbox_id Type : KVM\n "; }
    my $ua = LWP::UserAgent->new;
    $ua->ssl_opts(verify_hostname => 0, SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE);
    $ua->default_header('Authorization' => "PVEAPIToken=$proxmox_token_id=$proxmox_token_secret");
    
    my $config_url = "$proxmox_api_url/json/nodes/$proxmox_node/qemu/$vm_id/config";
    my $network_url = "$proxmox_api_url/json/nodes/$proxmox_node/qemu/$vm_id/agent/network-get-interfaces";
    my $netbox_virt_int_url = "virtualization/interfaces/";
    my $netbox_ip_int_url = "ipam/ip-addresses/";
    my $netbox_disk_url = 'virtualization/virtual-disks/';

    my $config_res = $ua->get($config_url);
    unless ($config_res->is_success) {
        print "Failed to get proxmox VM $vm_id config data: ", $config_res->status_line, "\n";
        return;
    }
    my $config_data = decode_json($config_res->decoded_content);

    my $network_res = $ua->get($network_url);
    unless ($network_res->is_success) {
        print "Failed to get proxmox VM $vm_id network data: ", $network_res->status_line, "\n";
        return;
    }
    my $network_data = decode_json($network_res->decoded_content);

    my $interface_list = $network_data->{data}->{result};
    unless (ref($interface_list) eq 'ARRAY') {
        print "Unexpected network response format: " . Dumper($network_data);
        return;
    }

    my $config_list = $config_data->{data};
    my $data = $config_data->{data};
    unless ($data && ref($data) eq 'HASH') {
        print "Unexpected config response format: " . Dumper($config_data);
        return;
    }

    my $netbox_response = $netbox_ua->get("$netbox_api_url$netbox_virt_int_url?virtual_machine_id=$netbox_id");
    die "Failed to get NetBox VM data: ", $netbox_response->status_line unless $netbox_response->is_success;
    my $netbox_data = decode_json($netbox_response->decoded_content);

    my $netbox_disk_response = $netbox_ua->get("$netbox_api_url$netbox_disk_url?virtual_machine_id=$netbox_id");
    die "Failed to get NetBox VM data: ", $netbox_disk_response->status_line unless $netbox_disk_response->is_success;
    my $netbox_disk_data = decode_json($netbox_disk_response->decoded_content);

    my %netbox_int;
    foreach my $int (@{$netbox_data->{results}}) {
        $netbox_int{$int->{name}} = {
            id                  => $int->{id},
            name                => $int->{name},
            mac_address         => $int->{mac_address},
        };
    }

    my %netbox_disk;
    foreach my $disk (@{$netbox_disk_data->{results}}) {
        $netbox_disk{$disk->{name}} = {
            id                  => $disk->{id},
            name                => $disk->{name},
            size                => $disk->{size},
            virtual_machine_id  => $disk->{virtual_machine_id}
        };
    }

    my %interfaces;
    foreach my $iface (@$interface_list) {
        my $iface_name = $iface->{name};
        my $proxmox_ips = { map { $_->{'ip-address'} => $_->{'prefix'} } @{$iface->{'ip-addresses'} || []} };

        if (exists($netbox_int{$iface->{name}})) {
            if($debug) { print "\tChecking Virtual Interface $iface->{name} in NetBox...\n";}
            my $net_int = $netbox_int{$iface->{name}}->{id};

            my $update_payload = {
                name        => $iface->{name},
                mac_address => $iface->{"hardware-address"},
                virtual_machine => $netbox_id,
            };

            my $json_payload = encode_json($update_payload);
            my $update_response = $netbox_ua->put("$netbox_api_url$netbox_virt_int_url$net_int/",
                'Content-Type' => 'application/json',
                Content => $json_payload
            );

            if ($update_response->is_success) {
                my $response_data = eval { decode_json($update_response->decoded_content) };
                if ($@) {
                    warn "Failed to decode response JSON for interface $iface->{name}: $@";
                    return;
                }

                my $netbox_ip_response = $netbox_ua->get("$netbox_api_url$netbox_ip_int_url?virtual_machine_id=$netbox_id&vminterface=$iface->{name}");
                die "Failed to get NetBox VM data: ", $netbox_ip_response->status_line unless $netbox_ip_response->is_success;
                my $netbox_ip_data = decode_json($netbox_ip_response->decoded_content);

                my %netbox_ips = map { $_->{address} =~ m{^([^/]+)} ? ($1 => $_->{prefix}) : () } @{$netbox_ip_data->{results} || []};
                # print "NetBox IPs for interface $iface_name:\n", Dumper(\%netbox_ips), "\n" if $debug;

                my @extra_in_netbox = grep { !exists $proxmox_ips->{$_} } keys %netbox_ips;

                foreach my $ip (@extra_in_netbox) {
                    my $ip_id = (grep { $_->{address} =~ m{^$ip/} } @{$netbox_ip_data->{results}})[0]->{id};
                    if($debug) { print "\textra IP : $ip_id\n"; }
                    next unless $ip_id;
                    my $delete_res = $netbox_ua->delete("$netbox_api_url$netbox_ip_int_url$ip_id/");
                    if ($delete_res->is_success) {
                        if($debug) { print "Removed extra IP $ip from NetBox for interface $iface_name.\n"; }
                    } else {
                        warn "Failed to remove IP $ip from NetBox: ", $delete_res->status_line;
                    }
                }

                if (exists $response_data->{id}) {
                    my $interface_id = $response_data->{id};
                    foreach my $ip (@{$iface->{ 'ip-addresses' }}) {
                        my $ipaddr   = $ip->{'ip-address'};
                        my $netmask  = $ip->{'prefix'};
                        next if ($ipaddr eq '127.0.0.1' || $ipaddr eq '::1');
                        vm_ip_int('add',$interface_id,$ipaddr,$netmask,$proxmox_api_url,$ua,$netbox_api_url,$netbox_ua);
                    }
                }

            } else {
                warn "Failed to update int $iface->{name}: ", $update_response->status_line, "\n";
            }
        } else {
            if($debug) { print "Adding int $iface->{name} to $netbox_id in NetBox...\n"; }

            my $insert_payload = {
                name        => $iface->{name},
                mac_address => $iface->{"hardware-address"},
                virtual_machine => $netbox_id,
            };

            my $json_payload = encode_json($insert_payload);
            my $post_response = $netbox_ua->post("$netbox_api_url$netbox_virt_int_url",
                'Content-Type' => 'application/json',
                Content => $json_payload
            );

            if ($post_response->is_success) {
                my $response_data = eval { decode_json($post_response->decoded_content) };
                if ($@) {
                    warn "Failed to decode response JSON for interface $iface->{name}: $@";
                    return;
                }
                if (exists $response_data->{id}) {
                    my $interface_id = $response_data->{id};
                    foreach my $ip (@{$iface->{ 'ip-addresses' }}) {
                        my $ipaddr   = $ip->{'ip-address'};
                        my $netmask  = $ip->{'prefix'};
                        next if ($ipaddr eq '127.0.0.1' || $ipaddr eq '::1');
                        vm_ip_int('add',$interface_id,$ipaddr,$netmask,$proxmox_api_url,$ua,$netbox_api_url,$netbox_ua);
                    }
                }
                if($debug) { print "Added int $iface->{name} to $netbox_id in NetBox.\n"; }
            } else {
                warn "Failed to add int $iface->{name}: ", $post_response->status_line, "\n";
            }
        }
    }

    if($debug) { print "\tChecking disks for Netbox Device : $netbox_id\n"; }
    kvm_disk($netbox_id, $proxmox_node, $vm_id, $proxmox_api_url, $ua, $netbox_api_url, $netbox_disk_url, $netbox_token, $netbox_ua);
}

sub lxc_import_netbox {
    my ($vm_id, $proxmox_api_url, $proxmox_token_id, $proxmox_token_secret, $proxmox_node, $netbox_api_url, $netbox_token, $netbox_id) = @_;
    if($debug) { print "Checking LXC server in netbox\n"; }
    if($debug) {  print "VM ID : $vm_id, Node : $proxmox_node, Netbox ID : $netbox_id Type : LXC\n"; }
    my $ua = LWP::UserAgent->new;
    $ua->ssl_opts(verify_hostname => 0, SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE);
    $ua->default_header('Authorization' => "PVEAPIToken=$proxmox_token_id=$proxmox_token_secret");
    
    my $config_url = "$proxmox_api_url/json/nodes/$proxmox_node/lxc/$vm_id/config";
    my $network_url = "$proxmox_api_url/json/nodes/$proxmox_node/lxc/$vm_id/interfaces";
    my $netbox_virt_int_url = "virtualization/interfaces/";
    my $netbox_ip_int_url = "ipam/ip-addresses/";
    my $netbox_disk_url = 'virtualization/virtual-disks/';

    my $config_res = $ua->get($config_url);
    unless ($config_res->is_success) {
        print "Failed to get proxmox VM $vm_id config data: ", $config_res->status_line, "\n";
        return;
    }
    my $config_data = decode_json($config_res->decoded_content);

    my $network_res = $ua->get($network_url);
    unless ($network_res->is_success) {
        print "Failed to get proxmox VM $vm_id network data: ", $network_res->status_line, "\n";
        return;
    }
    my $network_data = decode_json($network_res->decoded_content);

    my $interface_list = $network_data->{data};

    my $config_list = $config_data->{data};
    my $data = $config_data->{data};
    unless ($data && ref($data) eq 'HASH') {
        print "Unexpected config response format: " . Dumper($config_data);
        return;
    }

    my $netbox_response = $netbox_ua->get("$netbox_api_url$netbox_virt_int_url?virtual_machine_id=$netbox_id");
    die "Failed to get NetBox VM data: ", $netbox_response->status_line unless $netbox_response->is_success;
    my $netbox_data = decode_json($netbox_response->decoded_content);

    my $netbox_disk_response = $netbox_ua->get("$netbox_api_url$netbox_disk_url?virtual_machine_id=$netbox_id");
    die "Failed to get NetBox VM data: ", $netbox_disk_response->status_line unless $netbox_disk_response->is_success;
    my $netbox_disk_data = decode_json($netbox_disk_response->decoded_content);

    my %netbox_int;
    foreach my $int (@{$netbox_data->{results}}) {
        $netbox_int{$int->{name}} = {
            id                  => $int->{id},
            name                => $int->{name},
            mac_address         => $int->{mac_address},
        };
    }

    my %netbox_disk;
    foreach my $disk (@{$netbox_disk_data->{results}}) {
        $netbox_disk{$disk->{name}} = {
            id                  => $disk->{id},
            name                => $disk->{name},
            size                => $disk->{size},
            virtual_machine_id  => $disk->{virtual_machine_id}
        };
    }

    my %interfaces;
    foreach my $iface (@$interface_list) {
        my $iface_name = $iface->{name};
        my $proxmox_ips = {};
        
        for my $key (qw(inet inet6)) {
            if (exists $iface->{$key} && defined $iface->{$key}) {
                my ($ip, $prefix) = split('/', $iface->{$key}, 2);
                $proxmox_ips->{$ip} = $prefix || 'unknown';
            }
        }

        if (exists($netbox_int{$iface->{name}})) {
            if($debug) { print "\tChecking Virtual Interface $iface->{name} in NetBox...\n";}
            my $net_int = $netbox_int{$iface->{name}}->{id};

            my $update_payload = {
                name        => $iface->{name},
                mac_address => $iface->{hwaddr},
                virtual_machine => $netbox_id,
            };

            my $json_payload = encode_json($update_payload);
            my $update_response = $netbox_ua->put("$netbox_api_url$netbox_virt_int_url$net_int/",
                'Content-Type' => 'application/json',
                Content => $json_payload
            );

            if ($update_response->is_success) {
                my $response_data = eval { decode_json($update_response->decoded_content) };
                if ($@) {
                    warn "Failed to decode response JSON for interface $iface->{name}: $@";
                    return;
                }

                my $netbox_ip_response = $netbox_ua->get("$netbox_api_url$netbox_ip_int_url?virtual_machine_id=$netbox_id&vminterface=$iface->{name}");
                die "Failed to get NetBox VM data: ", $netbox_ip_response->status_line unless $netbox_ip_response->is_success;
                my $netbox_ip_data = decode_json($netbox_ip_response->decoded_content);

                my %netbox_ips = map { $_->{address} =~ m{^([^/]+)} ? ($1 => $_->{prefix}) : () } @{$netbox_ip_data->{results} || []};

                my @extra_in_netbox = grep { !exists $proxmox_ips->{$_} } keys %netbox_ips;

                foreach my $ip (@extra_in_netbox) {
                    my $ip_id = (grep { $_->{address} =~ m{^$ip/} } @{$netbox_ip_data->{results}})[0]->{id};
                    if($debug) { print "\textra IP : $ip_id\n"; }
                    next unless $ip_id;
                    my $delete_res = $netbox_ua->delete("$netbox_api_url$netbox_ip_int_url$ip_id/");
                    if ($delete_res->is_success) {
                        if($debug) { print "Removed extra IP $ip from NetBox for interface $iface_name.\n"; }
                    } else {
                        warn "Failed to remove IP $ip from NetBox: ", $delete_res->status_line;
                    }
                }

                if (exists $response_data->{id}) {
                    my $interface_id = $response_data->{id};
                    foreach my $ip (keys %$proxmox_ips) {
                        my $ipaddr   = $ip;
                        my $netmask  = $proxmox_ips->{$ip};
                        next if ($ipaddr eq '127.0.0.1' || $ipaddr eq '::1');
                        vm_ip_int('add',$interface_id,$ipaddr,$netmask,$proxmox_api_url,$ua,$netbox_api_url,$netbox_ua);
                    }
                }

            } else {
                warn "Failed to update int $iface->{name}: ", $update_response->status_line, "\n";
            }
        } else {
            if($debug) { print "Adding int $iface->{name} to $netbox_id in NetBox...\n"; }

            my $insert_payload = {
                name        => $iface->{name},
                mac_address => $iface->{"hwaddr"},
                virtual_machine => $netbox_id,
            };

            my $json_payload = encode_json($insert_payload);
            my $post_response = $netbox_ua->post("$netbox_api_url$netbox_virt_int_url",
                'Content-Type' => 'application/json',
                Content => $json_payload
            );

            if ($post_response->is_success) {
                my $response_data = eval { decode_json($post_response->decoded_content) };
                if ($@) {
                    warn "Failed to decode response JSON for interface $iface->{name}: $@";
                    return;
                }
                if (exists $response_data->{id}) {
                    my $interface_id = $response_data->{id};
                    foreach my $ip (keys %$proxmox_ips) {
                        my $ipaddr   = $ip;
                        my $netmask  = $proxmox_ips->{$ip};
                        next if ($ipaddr eq '127.0.0.1' || $ipaddr eq '::1');
                        vm_ip_int('add',$interface_id,$ipaddr,$netmask,$proxmox_api_url,$ua,$netbox_api_url,$netbox_ua);
                    }
                }
                if($debug) { print "Added int $iface->{name} to $netbox_id in NetBox.\n"; }
            } else {
                warn "Failed to add int $iface->{name}: ", $post_response->status_line, "\n";
            }
        }
    }



    if($debug) { print "\tChecking disks for Netbox Device : $netbox_id\n"; }
    lxc_disk($netbox_id, $proxmox_node, $vm_id, $proxmox_api_url, $ua, $netbox_api_url, $netbox_disk_url, $netbox_token, $netbox_ua);
}

sub vm_ip_int {
    my ($method, $vm_int, $ipaddr, $netmask, $proxmox_api_url, $ua, $netbox_api_url, $netbox_ua) = @_;   

    $ipaddr =~ s/%[^%]*$//;
    if($ipaddr =~ /:/) {
        $ipaddr =~ s/\./:/g;
    }

    if ($netmask !~ /^(?:\d{1,3})$/ || $netmask < 1 || $netmask > 128) {
        if($ipaddr =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/) {    
            $netmask = '32';
        } elsif($ipaddr =~ /:/) {
            $netmask = '128';
        } else {
            print "\t\t\bnot sure on the netmask, moving on";
            return;
        }
    }

    my $networkaddr;
    if (is_valid_ipv4($ipaddr)) {
        if ($netmask < 1 || $netmask > 32) {
            print "Invalid IPv4 netmask: $netmask\n";
            return;
        }
        $networkaddr = $ipaddr . "/" . $netmask;
    } elsif (is_valid_ipv6($ipaddr)) {
        if ($netmask < 1 || $netmask > 128) {
            print "Invalid IPv6 netmask: $netmask\n";
            return;
        }
        $networkaddr = $ipaddr . "/" . $netmask;
    } else {
        print "\n\n\nIP is invalid, please audit this and try again: $ipaddr\n\n\n";
        return;
    }

    if($method eq 'add') {
        if($debug) {  print "\t\tVM interface : $vm_int, IP address : $networkaddr\n"; }
        
        my $netbox_ip_addresses_url = "ipam/ip-addresses/";

        my $netbox_response = $netbox_ua->get("$netbox_api_url$netbox_ip_addresses_url?address=$ipaddr");
        die "Failed to get NetBox VM data: ", $netbox_response->status_line unless $netbox_response->is_success;
        my $netbox_data = decode_json($netbox_response->decoded_content);

            #curl -k -X GET 'https://10.180.22.39:8006/api2/virtualization/interfaces/?$netbox_id' -H 'Authorization: PVEAPIToken=root@pam%21Automation=123456789'

        my %netbox_addr;
        foreach my $addr (@{$netbox_data->{results}}) {
            $netbox_addr{$addr->{address}} = {
                address             => $addr->{address},
                assigned_object_type => $addr->{assigned_object_type},
                assigned_object_id  => $addr->{assigned_object_id},
            };
        }

        if (!exists($netbox_addr{$networkaddr})) {
            if($debug) { print "\t\t\tAdding address $networkaddr to NetBox...\n"; }
            
            my $insert_payload = {
                address             => $networkaddr,
                assigned_object_type => 'virtualization.vminterface',
                assigned_object_id  => $vm_int,
            };

            my $json_payload = encode_json($insert_payload);
            my $post_response = $netbox_ua->post("$netbox_api_url$netbox_ip_addresses_url",
                'Content-Type' => 'application/json',
                Content => $json_payload
            );

            if ($post_response->is_success) {
                if($debug) { print "\t\t\t\tAdded IP $networkaddr to $vm_int in NetBox.\n"; }
            } else {
                warn "Failed to add IP $networkaddr: ", $post_response->status_line, "\n";
            }
        } else {
            if($debug) { print "\t\t\tIP already exists in the DB.\n"; }
        }
    } else {
        print "we have been called an undefined method with $networkaddr\n";
    }
}

sub kvm_disk {
    my ($netbox_id, $proxmox_node, $vm_id, $proxmox_api_url, $ua, $netbox_api_url, $netbox_disk_url, $netbox_token, $netbox_ua) = @_;

    my $config_url = "$proxmox_api_url/json/nodes/$proxmox_node/qemu/$vm_id/config";

    my $config_res = $ua->get($config_url);
        die "Failed to get proxmox VM network data: ", $config_res->status_line unless $config_res->is_success;
    my $config_data = decode_json($config_res->decoded_content);
    my $data = $config_data->{data};

    my %disks;
    my @disk_types = qw(virtio scsi sata ide);

    foreach my $type (@disk_types) {
        foreach my $key (keys %$data) {
            if ($key =~ /^$type(\d+)$/) {
                my $disk_id = $1;
                my $name = $type . $disk_id;
                
                my ($disk_path, $disk_size) = $data->{$key} =~ /(.*?),.*?size=(\d+\w*)/;
                
                if (defined($disk_size)) {
                    if ($disk_size =~ /(\d+)([A-Za-z]*)/) {
                        my $size_value = $1;
                        my $size_unit  = $2;
                        
                        my $normalized_size = ($size_unit eq "T") ? ($size_value * 1024) : $size_value;

                        $disks{"$type$disk_id"} = { path => $disk_path, size => $normalized_size, name => $name };
                    }
                }
            }
        }
    }

    my $netbox_disk_response = $netbox_ua->get("$netbox_api_url$netbox_disk_url?virtual_machine_id=$netbox_id");
    die "Failed to get NetBox VM data: ", $netbox_disk_response->status_line unless $netbox_disk_response->is_success;
    my $netbox_disk_data = decode_json($netbox_disk_response->decoded_content);

    my %netbox_disks;
    foreach my $disk (@{$netbox_disk_data->{results}}) {
        my $netbox_disk_id = $disk->{id};  # Assuming the NetBox API response contains a unique 'id' for each disk
        $netbox_disks{$netbox_disk_id} = { description => $disk->{path}, size => $disk->{size}, name => $disk->{name} };
    }

    foreach my $netbox_disk_id (keys %netbox_disks) {
        my $found = 0;
        foreach my $disk_key (keys %disks) {
            my $disk = $disks{$disk_key};

            if (defined $netbox_disks{$netbox_disk_id}->{name} && $netbox_disks{$netbox_disk_id}->{name} ne "" &&
                defined $disk->{name} && $disk->{name} ne "" &&
                $netbox_disks{$netbox_disk_id}->{name} eq $disk->{name}) {
                $found = 1;
                last;
            }
        }

        unless ($found) {
            if($debug) { print "\t\tRemoving disk $netbox_disks{$netbox_disk_id}->{name} (ID: $netbox_disk_id) from NetBox\n"; }

            my $delete_url = "$netbox_api_url$netbox_disk_url$netbox_disk_id/";
            my $delete_response = $netbox_ua->delete(
                $delete_url,
                'Authorization' => "Token $netbox_token"
            );

            if($debug) { print "delete url is : $delete_url\n"; }

            if ($delete_response->is_success) {
                if($debug) { print "\t\t\tSuccessfully removed disk $netbox_disks{$netbox_disk_id}->{name} from NetBox.\n"; }
            } else {
                warn "Failed to remove disk $netbox_disks{$netbox_disk_id}->{name}: ", $delete_response->status_line, "\n";
            }
        }
    }

    foreach my $disk_key (keys %disks) {
        my ($disk_type, $disk_id) = $disk_key =~ /^(\w+)(\d+)$/;
        my $disk = $disks{$disk_key};

        if($debug) { print "\t\tChecking disk $disks{$disk_key}{name}\n"; }
        if(!defined $disks{$disk_key}{path}) { 
            if($debug) { print "skipping disk, has no path and likely a CD drive"; }
            next; 
        }

        my $found = 0;
        foreach my $netbox_disk_id (keys %netbox_disks) {
            if (defined $netbox_disks{$netbox_disk_id}->{name} && $netbox_disks{$netbox_disk_id}->{name} ne "" &&
                defined $disk->{name} && $disk->{name} ne "" &&
                $netbox_disks{$netbox_disk_id}->{name} eq $disk->{name}) {
                $found = 1;
                last; 
            }
        }

        unless ($found) {
            my $add_disk_url = "$netbox_api_url$netbox_disk_url";
            my $add_disk_data = {
                virtual_machine    => $netbox_id,
                description        => $disks{$disk_key}{path},
                size               => $disks{$disk_key}{size},
                name               => $disks{$disk_key}{name},
            };

            my $json_payload = encode_json($add_disk_data);
            my $post_response = $netbox_ua->post("$netbox_api_url$netbox_disk_url",
                'Content-Type' => 'application/json',
                Content => $json_payload
            );

            if ($post_response->is_success) {
                if($debug) { print "Added disk to $vm_id in NetBox.\n"; }
            } else {
                warn "Failed to add disk : ", $post_response->status_line, "\n";
            }
        }
    }
}

sub lxc_disk {
    my ($netbox_id, $proxmox_node, $vm_id, $proxmox_api_url, $ua, $netbox_api_url, $netbox_disk_url, $netbox_token, $netbox_ua) = @_;

    my $config_url = "$proxmox_api_url/json/nodes/$proxmox_node/lxc/$vm_id/config";

    my $config_res = $ua->get($config_url);
        die "Failed to get proxmox VM network data: ", $config_res->status_line unless $config_res->is_success;
    my $config_data = decode_json($config_res->decoded_content);
    my $data = $config_data->{data};

    my %disks;
    my @disk_types = qw(rootfs);

    foreach my $type (@disk_types) {
        foreach my $key (keys %$data) {
            if ($key =~ /^$type/) {
                my $name = $type;
                my ($disk_path, $disk_size) = $data->{$key} =~ /(.*?),.*?size=(\d+\w*)/;
                
                if (defined($disk_size)) {
                    if ($disk_size =~ /(\d+)([A-Za-z]*)/) {
                        my $size_value = $1;
                        my $size_unit  = $2;
                        
                        my $normalized_size = ($size_unit eq "T") ? ($size_value * 1024) : $size_value;

                        $disks{"$type"} = { path => $disk_path, size => $normalized_size, name => $name };
                    }
                }
            }
        }
    }

    my $netbox_disk_response = $netbox_ua->get("$netbox_api_url$netbox_disk_url?virtual_machine_id=$netbox_id");
    die "Failed to get NetBox VM data: ", $netbox_disk_response->status_line unless $netbox_disk_response->is_success;
    my $netbox_disk_data = decode_json($netbox_disk_response->decoded_content);

    my %netbox_disks;
    foreach my $disk (@{$netbox_disk_data->{results}}) {
        my $netbox_disk_id = $disk->{id};  # Assuming the NetBox API response contains a unique 'id' for each disk
        $netbox_disks{$netbox_disk_id} = { description => $disk->{path}, size => $disk->{size}, name => $disk->{name} };
    }

    foreach my $netbox_disk_id (keys %netbox_disks) {
        my $found = 0;
        foreach my $disk_key (keys %disks) {
            my $disk = $disks{$disk_key};

            if (defined $netbox_disks{$netbox_disk_id}->{name} && $netbox_disks{$netbox_disk_id}->{name} ne "" &&
                defined $disk->{name} && $disk->{name} ne "" &&
                $netbox_disks{$netbox_disk_id}->{name} eq $disk->{name}) {
                $found = 1;
                last;
            }
        }

        unless ($found) {
            if($debug) { print "\t\tRemoving disk $netbox_disks{$netbox_disk_id}->{name} (ID: $netbox_disk_id) from NetBox\n"; }

            my $delete_url = "$netbox_api_url$netbox_disk_url$netbox_disk_id/";
            my $delete_response = $netbox_ua->delete(
                $delete_url,
                'Authorization' => "Token $netbox_token"
            );

            if($debug) { print "delete url is : $delete_url\n"; }

            if ($delete_response->is_success) {
                if($debug) { print "\t\t\tSuccessfully removed disk $netbox_disks{$netbox_disk_id}->{name} from NetBox.\n"; }
            } else {
                warn "Failed to remove disk $netbox_disks{$netbox_disk_id}->{name}: ", $delete_response->status_line, "\n";
            }
        }
    }

    foreach my $disk_key (keys %disks) {
        my ($disk_type, $disk_id) = $disk_key =~ /^(\w+)(\d+)$/;
        my $disk = $disks{$disk_key};

        if($debug) { print "\t\tChecking disk $disks{$disk_key}{name}\n"; }
        if(!defined $disks{$disk_key}{path}) { 
            if($debug) { print "skipping disk, has no path and likely a CD drive"; }
            next; 
        }

        my $found = 0;
        foreach my $netbox_disk_id (keys %netbox_disks) {
            if (defined $netbox_disks{$netbox_disk_id}->{name} && $netbox_disks{$netbox_disk_id}->{name} ne "" &&
                defined $disk->{name} && $disk->{name} ne "" &&
                $netbox_disks{$netbox_disk_id}->{name} eq $disk->{name}) {
                $found = 1;
                last; 
            }
        }

        unless ($found) {
            my $add_disk_url = "$netbox_api_url$netbox_disk_url";
            my $add_disk_data = {
                virtual_machine    => $netbox_id,
                description        => $disks{$disk_key}{path},
                size               => $disks{$disk_key}{size},
                name               => $disks{$disk_key}{name},
            };

            my $json_payload = encode_json($add_disk_data);
            my $post_response = $netbox_ua->post("$netbox_api_url$netbox_disk_url",
                'Content-Type' => 'application/json',
                Content => $json_payload
            );

            if ($post_response->is_success) {
                if($debug) { print "Added disk to $vm_id in NetBox.\n"; }
            } else {
                warn "Failed to add disk : ", $post_response->status_line, "\n";
            }
        }
    }
}


sub proxmox_node {
    my ($node_name,$cluster,$site,$status,$proxmox_api_url,$ua,$netbox_api_url,$netbox_ua) = @_;   

    if($debug) {  print "\tChecking to see if node $node_name in $cluster cluster exists\n"; }
    
    my $netbox_dcim_device_url = "dcim/devices/";

    my $netbox_response = $netbox_ua->get("$netbox_api_url$netbox_dcim_device_url?name=$node_name&cluster_id=$cluster");
    die "Failed to get NetBox VM data: ", $netbox_response->status_line unless $netbox_response->is_success;

    my $netbox_data;
    eval { $netbox_data = decode_json($netbox_response->decoded_content); };
    if ($@) {
        die "Failed to parse NetBox JSON response: $@";
    }

    if (exists $netbox_data->{results} && @{$netbox_data->{results}} > 0) {
        if ($debug) { print "\t\tNode $node_name exists in NetBox.\n"; }
        return 1;
    } else {
        if ($debug) { print "\t\tNode $node_name does not exist in NetBox, adding ... \n"; }
        my $insert_payload = {
            name         => $node_name,
            device_type  => 17,
            role         => 1,
            site         => $site,
            cluster      => $cluster,
            status       => $status,
        };

        my $json_payload = encode_json($insert_payload);
        my $post_response = $netbox_ua->post("$netbox_api_url$netbox_dcim_device_url",
            'Content-Type' => 'application/json',
            Content => $json_payload
        );

        if ($post_response->is_success) {
            if ($debug) { print "\t\t\tAdded node $node_name to NetBox.\n"; }
            return 1;
        } else {
            warn "Failed to add node $node_name: ", $post_response->status_line, "\n";
            return 0;
        }
    }
}

sub is_valid_ipv4 {
    my $ip = shift;
    return $ip =~ /^(?:\d{1,3}\.){3}\d{1,3}$/ && !grep { $_ > 255 } split(/\./, $ip);
}

sub is_valid_ipv6 {
    my $ip = shift;
    return $ip =~ /^[a-fA-F0-9:]+$/ && $ip =~ /:/;
}