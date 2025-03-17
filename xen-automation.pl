#!/usr/bin/perl
#
# written by Neil Sayers
#
# automate the addition of VM's that are in the virtual environments, and remove any that do not exist, keep them updated.
# ./xen_automation.pl

use strict;
use warnings;
use Data::Dumper;
use Getopt::Long;
use JSON;
use LWP::UserAgent;
use RPC::XML::Client;
use Iso::XenConfig;

our $netbox_device_url = "dcim/devices/";
our $netbox_virt_int_url = "virtualization/interfaces/";
our $netbox_ip_int_url = "ipam/ip-addresses/";
our $netbox_disk_url = 'virtualization/virtual-disks/';
our $netbox_virtualization_url = "virtualization/virtual-machines/";

my ($virtual_cluster, $url, $domain, $user, $pass, $session_response, $client);

my $excluded; # grab skipped info, so we can export it at the end if called.
our $debug = 0;

GetOptions(
  'cluster|c=s' => \$virtual_cluster,
  'query|q=s' => \$url,
  'domain|d=s' => \$domain,
  'user|u=s' => \$user,
  'pass|p=s' => \$pass,
  'debug|v' => \$debug,
  'help|?' => sub { HelpMessage() },
)  or die HelpMessage();

if(!defined($virtual_cluster)){ 
    HelpMessage();
    die "Error: No cluster defined\n"; 
}

my $xserver = XenConfig::get_xenserver($virtual_cluster);

if (!$xserver) {
    die "Error: No XenServer found for cluster '$virtual_cluster'\n";
}

our $xenserver = $url // $xserver->{url};
our $xenuser = $user // $xserver->{xenuser};
our $xenpass = $pass // $xserver->{xenpass};
our $domainname = $domain // $xserver->{domainname};
our $cluster = $xserver->{cluster};
our $site = $xserver->{site};
our $netbox_api_url = $xserver->{netbox_api_url};
our $netbox_token = $xserver->{netbox_token};
my $xenversion = $xserver->{xenversion};

my ($xenLogin, $xenAllRecords, $xenVBDRecord, $xenVDIRecord, $xenVIFRecord, $xenVMMetrix, $xenLogOut); 
if($xenversion eq '6.5') {
    $xenLogin = 'session.login_with_password';
    $xenAllRecords =  'VM.get_all_records';
    $xenVBDRecord = 'VBD.get_record';
    $xenVDIRecord = 'VDI.get_record';
    $xenVIFRecord = 'VIF.get_record';
    $xenVMMetrix = 'VM_guest_metrics.get_record';
    $xenLogOut = 'session.logout';
} elsif($xenversion eq '7.0') {
    $xenLogin = 'session.login_with_password';
    $xenAllRecords =  'VM.get_all_records';
    $xenVBDRecord = 'VBD.get_record';
    $xenVDIRecord = 'VDI.get_record';
    $xenVIFRecord = 'VIF.get_record';
    $xenVMMetrix = 'VM_guest_metrics.get_record';
    $xenLogOut = 'session.logout';
} elsif($xenversion eq '8.1') {
    $xenLogin = 'session.login_with_password';
    $xenAllRecords =  'VM.get_all_records';
    $xenVBDRecord = 'VBD.get_record';
    $xenVDIRecord = 'VDI.get_record';
    $xenVIFRecord = 'VIF.get_record';
    $xenVMMetrix = 'VM_guest_metrics.get_record';
    $xenLogOut = 'session.logout';
} else {
    print "Undefined version, please escalate to admin\n";
    exit;
}

print "$virtual_cluster automation ran at " . localtime . "\n";

if(defined($xenLogin)) {
    $client = RPC::XML::Client->new($xenserver);
    $session_response = $client->simple_request($xenLogin, $xenuser, $xenpass);
} else {
    print "Undefined version, please escalate to admin\n";
    exit;
}

my $session;
if (defined($session_response) && ref($session_response) eq 'HASH' && $session_response->{Status} eq 'Success') {
    $session = $session_response->{Value};
    # if($debug) { print "Session OpaqueRef: $session\n"; }
} else {
    die "Authentication failed! Invalid session response: " . Dumper($session_response);
}

our $netbox_ua = LWP::UserAgent->new;
    $netbox_ua->default_header('Authorization' => "Token $netbox_token");

#my $netbox_data = fetch_netbox_vms($netbox_ua, $netbox_api_url, $netbox_virtualization_url, $cluster_id);

my $vms_response = $client->simple_request($xenAllRecords, $session);

if (!defined $vms_response) {
    die "No response from VM.get_all_records\n";
} elsif (ref($vms_response) ne 'HASH') {
    die "Unexpected response type from VM.get_all_records: " . Dumper($vms_response);
}

my $vms = $vms_response->{Value};

foreach my $vm_ref (keys %$vms) {
    my $memory;
    my $record = $vms->{$vm_ref};

    ##
    ## Get the basics of the system
    ## 

    my $name_label = $record->{name_label} // "Unknown";
    my $power_state = $record->{power_state} // "Unknown";
    my $vcpu_max = $record->{VCPUs_max} // "Unknown";
    my $memory_dynamic_max = $record->{memory_dynamic_max} // "Unknown";
    my $memory_static_max = $record->{memory_static_max} // "Unknown";
    my $uuid = $record->{uuid} // "Unknown";
    my $is_snapshot = $record->{is_a_snapshot} // "Unknown";
    my $is_template = $record->{is_a_template} // "Unknown";

    if($name_label eq 'Unknown' || $power_state eq 'Unknown') {
        next;
    }

    if($name_label !~ m/\./) {
        $name_label .= "." . $domainname;
    }

    if(defined($memory_dynamic_max)){
        $memory = $memory_dynamic_max / (1024 * 1024);
    } elsif(defined($memory_static_max)) {
        $memory = $memory_static_max / (1024 * 1024);
    } else {
        $memory = '0';
    }

    if($is_snapshot eq '1' || $is_template eq '1') { 
        if($debug) { print "Found $name_label is a template/snapshot, skipping.\n"; }
        $excluded .= "VM Name: $name_label, Power State: $power_state, vCPUs: $vcpu_max, Memory: $memory, Template: $is_template, Snapshot: $is_snapshot\n"; 
        next; 
    }

    if($debug) { print "Checking for $record->{name_label} in netbox ....\n"; }

    if($name_label =~ m/Control domain on host/) { 
        my ($garbage, $node_name) = split(":", $name_label);
        xenserver_node($node_name,$cluster,$site,'active',$client,$netbox_api_url,$netbox_ua);
        next; 
    }

    $name_label =~ s/\s+//g;

    if($debug) { print "VM Name: $name_label, Power State: $power_state, vCPUs: $vcpu_max, Memory: $memory, Template: $is_template, Snapshot: $is_snapshot\n"; }

    ##
    ## Get the disks
    ##

    if($debug) { print "\tDisk assignments:\n"; }

    my $disk_assignments = [];
    my $vbd_refs = $record->{VBDs} // [];
    if (@$vbd_refs) {
        foreach my $vbd_ref (@$vbd_refs) {

            # Get the VBD record
            my $vbd_record = $client->simple_request($xenVBDRecord, $session, $vbd_ref);

            if ($vbd_record && ref($vbd_record) eq 'HASH') {
                my $vbd_value = $vbd_record->{Value} // {};  
                my $vbd_type = $vbd_value->{type} // 'Unknown'; 
                my $vbd_VDI = $vbd_value->{VDI} // 'Unknown';
                my $vbd_device = $vbd_value->{device} // 'Unknown';
                my $vdi_size_gb;

                # Skip if type is 'CD'
                if ($vbd_type eq 'CD') {
                    next;
                }

                my $vdi_record = $client->simple_request($xenVDIRecord, $session, $vbd_VDI);
                if ($vdi_record && ref($vdi_record) eq 'HASH' && exists $vdi_record->{Value}) {
                    my $vdi_size_bytes = $vdi_record->{Value}->{virtual_size} // 0;  
                    $vdi_size_gb = $vdi_size_bytes / (1024**3); 
                } else {
                    if($debug) { print "\tsomething went wrong, check $vbd_VDI for issues\n"; }
                    next;
                }

                push @$disk_assignments, { device => $vbd_device, type => $vbd_type, size_gb => $vdi_size_gb };

                if($debug) { print "\t\tDevice: $vbd_device, Type: $vbd_type, Size: $vdi_size_gb G\n"; }

            }


        }
    } else {
        if($debug) { print "No VBDs found for VM: $name_label\n"; } 
    }

    ##
    ## Get Network settings
    ## 
    if($debug) { print "\tNetwork Assignments:\n"; }

    my $network_assignments = [];
    my $vif_refs = $record->{VIFs} // [];
    my $nic_data;
    next unless @$vif_refs;
    
    foreach my $vif_ref (@$vif_refs) {
        my $vif_record = $client->simple_request($xenVIFRecord, $session, $vif_ref);
        
        if ($vif_record && ref($vif_record) eq 'HASH' && exists $vif_record->{Value}) {
            my $device = $vif_record->{Value}->{device} // "Unknown";
            my $mac_address = $vif_record->{Value}->{MAC} // "Unknown";
            my $network_ref = $vif_record->{Value}->{network} // "Unknown";

            #print "dumping network values, need to find the name : " . Dumper($vif_record);

            push @$network_assignments, { mac_address => $mac_address, name => $device, description => $network_ref };

            if($debug) { print "\t\tVIF MAC: $mac_address, Network: $network_ref\n"; }

            # Get VM Guest Metrics to find assigned IPs
            my $metrics_ref = $record->{guest_metrics} // "OpaqueRef:NULL";
            if ($metrics_ref ne "OpaqueRef:NULL") {
                my $metrics = $client->simple_request($xenVMMetrix, $session, $metrics_ref);
                
                if ($metrics && ref($metrics) eq 'HASH' && exists $metrics->{Value}) {

                    #print "Dumping NIC Data, this is not right\n" . Dumper($metrics) ."\n";

                    my $networks = $metrics->{Value}->{networks} // {};
                    foreach my $key (keys %$networks) {
                        ## Key + IPAllocation, we need to do something here.
                        my ($ifname) = $key =~ m{^([^/]+)}; 
                        my $nic_ip = $networks->{$key};
                        push @$nic_data, { name => $name_label, ipaddr => $nic_ip, iface => $ifname };
                    }
                }
            }
        } else {
            if($debug) { print "\tFailed to fetch VIF record for $vif_ref\n"; }
        }
    }

    my $vm_data = {
        name            => $name_label,
        status          => ($power_state eq 'Running') ? 'active' : 'offline',
        vcpus           => $vcpu_max,
        memory          => $memory,
        vmid            => $uuid,
        disk_assignments => $disk_assignments,
        networks        => $network_assignments,
    };

    update_or_add_vm($vm_data);
    
    foreach my $nic (@$nic_data) {
        # $vm_name, $mac_address, $ipaddr

        vm_ip_int($nic->{name}, $nic->{ipaddr}, $nic->{iface});
    }
}

#if($debug) { print "\nHere is the stuff that we will not be inserting : \n" . $excluded; }

# Logout only if the session was created successfully
my $logout = $client->simple_request($xenLogOut, $session);



sub xenserver_node {
    my ($node_name,$cluster,$site,$status,$client,$netbox_api_url,$netbox_ua) = @_; 

    if($debug) {  print "Checking to see if node $node_name in $cluster cluster exists\n"; }
    
    my $netbox_dcim_device_url = "dcim/devices/";

    my $netbox_response = $netbox_ua->get("$netbox_api_url$netbox_dcim_device_url?name=$node_name&cluster_id=$cluster");
    die "Failed to get NetBox VM data: ", $netbox_response->status_line unless $netbox_response->is_success;

    my $netbox_data;
    eval { $netbox_data = decode_json($netbox_response->decoded_content); };
    if ($@) {
        die "Failed to parse NetBox JSON response: $@";
    }

    if (exists $netbox_data->{results} && @{$netbox_data->{results}} > 0) {
        if ($debug) { print "\tNode $node_name exists in NetBox.\n"; }
        return 1;
    } else {
        if($debug) { print "\tNode $node_name does not exist in NetBox, adding ... \n"; }
        my $insert_payload = {
            name         => $node_name,
            device_type  => 17,
            role         => 5,
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
            if ($debug) { print "\t\tAdded node $node_name to NetBox.\n"; }
            return 1;
        } else {
            warn "Failed to add node $node_name: ", $post_response->status_line, "\n";
            return 0;
        }
    }
}


sub get_vm_from_db {
    my ($vm_name) = @_;
    my @all_vms;
    my $next_url = "$netbox_api_url$netbox_virtualization_url?cluster_id=$cluster&name=$vm_name";

    while ($next_url) {
        my $response = $netbox_ua->get($next_url);
        unless ($response->is_success) {
            die sprintf("Failed to get NetBox VM data (HTTP %s): %s\n",
                $response->code, $response->decoded_content);
        }

        my $data = decode_json($response->decoded_content);
        push @all_vms, @{$data->{results}};
        
        $next_url = $data->{next}; # Handle pagination
    }

    my %netbox_vms;
    foreach my $vm (@all_vms) {
        $netbox_vms{$vm->{name}} = {
            id      => $vm->{id},
            name    => $vm->{name},
            status  => $vm->{status}{label},
            vcpus   => $vm->{vcpus} // 0,
            memory  => $vm->{memory} // 0,
        };
    }

    return \%netbox_vms;  # Return the hash reference of all VMs
}


sub update_or_add_vm {
    my ($vm_data) = @_;

    # Check if VM exists (using cluster and VM's name)
    my $existing_vm = get_vm_from_db($vm_data->{name});  
    
    if (defined $existing_vm && keys %{$existing_vm}) {
        my $existing_vm_data = $existing_vm->{$vm_data->{name}};
        # VM exists, check if any updates are needed
        if (is_vm_data_changed($existing_vm, $vm_data)) {
            # Update VM data if there are changes
            update_vm_in_db($existing_vm->{name}, $vm_data);
            # print "Updated VM: $vm_data->{name}\n";  YOU LIE, you are not validating SHIT
            compare_disks($existing_vm_data->{id}, $vm_data->{disk_assignments});
            compare_interfaces($existing_vm_data->{id}, $vm_data->{networks});
        } else {
            if($debug) { print "\tNo core changes for VM: $vm_data->{name}\n"; }
            compare_disks($existing_vm_data->{id}, $vm_data->{disk_assignments});
            compare_interfaces($existing_vm_data->{id}, $vm_data->{networks}, $vm_data->{nic_allocations});
        }
    } else {
        # VM doesn't exist, add it
        add_vm_to_db($vm_data);
        # print "Added new VM: $vm_data->{name}\n";    # YOU LIE, you are not validating SHIT

        #compare_disks($existing_vm->{key}, $vm_data->{disk_assignments});
    }
}

# Example of a function that checks if VM data has changed
sub is_vm_data_changed {
    my ($existing_vm, $vm_data) = @_;
    if(!defined($existing_vm) || !defined($vm_data) ) { print "\tis_vm_data_changed being called to compare, but no vm_data being passed to something\n"; return 0;}

    my $existing_vm_data = $existing_vm->{$vm_data->{name}};

    if (!defined($existing_vm_data)) {
        if($debug) { print "\tNo existing VM data found for $vm_data->{name}\n"; }
        return 0;  # No existing VM data found for this VM name
    }

    # Compare existing VM data with new data
    return lc($existing_vm_data->{status}) ne lc($vm_data->{status}) ||  # Compare power state
           $existing_vm_data->{memory} ne $vm_data->{memory} ||  # Compare memory
           $existing_vm_data->{vcpus} ne $vm_data->{vcpus};
}

# Compare networks between the existing VM and the new data
sub compare_networks {
    my ($existing_networks, $new_networks) = @_;
    if(!defined($existing_networks) || !defined($new_networks) ) { print "\tcompare_networks being called to compare VM's, but no vm_data being passed\n"; }
    
    # Logic to compare network assignments (MAC address, network) between existing and new networks
    return 1 if scalar(@$existing_networks) != scalar(@$new_networks);  # Different number of networks
    for my $i (0 .. $#{$existing_networks}) {
        return 1 if $existing_networks->[$i]->{mac_address} ne $new_networks->[$i]->{mac_address} ||
                   $existing_networks->[$i]->{name} ne $new_networks->[$i]->{name};
    }
    return 0;
}

# Subroutine to add a new VM to the DB or NetBox
sub add_vm_to_db {
    my ($vm_data) = @_;

    if(!defined($vm_data)) { print "being called to add VM to DB, but no vm_data being passed\n"; return; }
    # Add the new VM data to the DB or API (e.g., NetBox)
    # This is a placeholder, replace with actual logic to add the VM.

    my $vm_name = $vm_data->{name};

    if($debug) { print "\tAdding VM $vm_name to NetBox...\n"; }

    my $insert_payload = {
        name    => $vm_name,
        status  => $vm_data->{status},
        site    => $site,
        cluster => $cluster,
        vcpus   => $vm_data->{vcpus} // 0,
        memory  => $vm_data->{memory} // 0,
        description => "xen VM ID: " . $vm_data->{vmid},
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

# Subroutine to update an existing VM in the DB or NetBox
sub update_vm_in_db {
    my ($vmid, $vm_data) = @_;

    if(!defined($vmid)) { print "being called to update, but no vmid being passed\n"; return; }
    # Update the VM data in the DB or API (e.g., NetBox)
    # This is a placeholder, replace with actual logic to update the VM.
    if($debug) { print "\t\tUpdating VM with UUID: $vmid\n\n\n"; }
}


sub compare_disks {
    my ($netbox_id, $new_disks) = @_;

    #print "Disks being passed to me to compare to $netbox_id: " . Dumper($new_disks);

    my $netbox_disk_response = $netbox_ua->get("$netbox_api_url$netbox_disk_url?virtual_machine_id=$netbox_id");
    die "Failed to get NetBox VM data: ", $netbox_disk_response->status_line unless $netbox_disk_response->is_success;
    my $netbox_disk_data = decode_json($netbox_disk_response->decoded_content);

    my %netbox_disks;
    foreach my $disk (@{$netbox_disk_data->{results}}) {
        my $netbox_disk_id = $disk->{id};
        $netbox_disks{$netbox_disk_id} = { description => $disk->{path}, size => $disk->{size}, name => $disk->{name} };
    }

    foreach my $new_disk (@$new_disks) {
        my $new_disk_name = $new_disk->{device};
        my $new_disk_size = $new_disk->{size_gb};

        #if($debug) { print "\t\tComparing new disk: $new_disk_name with NetBox disks...\n"; }

        # Check if the disk exists in NetBox
        my $found_match = 0;
        foreach my $netbox_disk_id (keys %netbox_disks) {
            my $netbox_disk = $netbox_disks{$netbox_disk_id};
            
            # Compare based on disk name and size
            if ($netbox_disk->{name} eq $new_disk_name && $netbox_disk->{size} == $new_disk_size) {
                $found_match = 1;
                if($debug) { print "\t\tMatch found for disk $new_disk_name\n"; }
                last;
            }
        }

        # If no match found, update or add the disk
        unless ($found_match) {
            if($debug) { print "\t\tNo match found for disk $new_disk_name. Adding to NetBox...\n"; }
            # Update or add new disk logic here.
            my $disk_data = {
                virtual_machine    => $netbox_id,
                description        => $new_disk_name,
                size               => $new_disk_size,
                name               => $new_disk_name,
            };
            my $json_payload = encode_json($disk_data);

            my $post_response = $netbox_ua->post("$netbox_api_url$netbox_disk_url",
                'Content-Type' => 'application/json',
                Content => $json_payload
            );
            
            if ($post_response->is_success) {
                if($debug) { print "\t\t\tAdded disk $new_disk_name to $netbox_id in NetBox.\n"; }
            } else {
                warn "Failed to add Disk $new_disk_name: ", $post_response->status_line, "\n";
            }
        }
    }

    # Now remove any disks from NetBox that were not found in the new disks array
    foreach my $netbox_disk_id (keys %netbox_disks) {
        my $netbox_disk = $netbox_disks{$netbox_disk_id};
        my $found_match = 0;

        # Check if the disk is in the new disks array
        foreach my $new_disk (@$new_disks) {
            my $new_disk_name = $new_disk->{device};
            my $new_disk_size = $new_disk->{size_gb} // 0;
            if ($netbox_disk->{name} eq $new_disk_name && $netbox_disk->{size} == $new_disk_size) {
                $found_match = 1;
                last;
            }
        }

        # If the disk is not found in the new disks array, remove it
        unless ($found_match) {
            if($debug) { print "\t\t\tDisk $netbox_disk->{name} not found in the new disks. Removing from NetBox...\n"; }
            my $delete_response = $netbox_ua->delete("$netbox_api_url$netbox_disk_url$netbox_disk_id");
            die "Failed to delete disk from NetBox: ", $delete_response->status_line unless $delete_response->is_success;
            if($debug) { print "\t\t\t\tDisk $netbox_disk->{name} successfully removed from NetBox.\n"; }
        }
    }
}

sub compare_interfaces {
    my ($netbox_id, $new_interfaces) = @_;

    my $netbox_if_response = $netbox_ua->get("$netbox_api_url$netbox_virt_int_url?virtual_machine_id=$netbox_id");
    die "Failed to get NetBox VM data: ", $netbox_if_response->status_line unless $netbox_if_response->is_success;
    my $netbox_if_data = decode_json($netbox_if_response->decoded_content);

    my %netbox_if;
    foreach my $iface (@{$netbox_if_data->{results}}) {
        my $netbox_if_id = $iface->{id};
        $netbox_if{$netbox_if_id} = {
            id              => $iface->{id},
            virtual_machine => $iface->{virtual_machine}{id},
            name            => $iface->{name},
            mac_address     => $iface->{mac_address},
            description     => $iface->{description}
        };
    }

    foreach my $new_interface (@$new_interfaces) {

        my $found_match = 0;
        foreach my $netbox_if_id (keys %netbox_if) {
            my $netbox_if = $netbox_if{$netbox_if_id};

            #if($debug) { print "\t\tComparing new interface: " . $new_interface->{name} . " = " . $netbox_if->{name} . " with MAC: " . lc($new_interface->{mac_address}) ." = " . lc($netbox_if->{mac_address}) . " with NetBox VM\n"; }
            if ($netbox_if->{name} eq $new_interface->{name} && lc($new_interface->{mac_address}) eq lc($netbox_if->{mac_address})) {
                $found_match = 1;
                last;
            }
        }

        unless ($found_match) {
            if($debug) { print "\t\tNo match found for interface: " . $new_interface->{name} . ", VM : " . $netbox_id . " . Adding to NetBox...\n"; }

            my $iface_data = {
                virtual_machine => $netbox_id,
                mac_address     => $new_interface->{mac_address},
                name            => $new_interface->{name},
                description     => $new_interface->{description},
            };

            my $json_payload = encode_json($iface_data);

            my $post_response = $netbox_ua->post(
                "$netbox_api_url$netbox_virt_int_url",
                'Content-Type' => 'application/json',
                Content        => $json_payload
            );

            # print "curl -X POST \"$netbox_api_url$netbox_virt_int_url\" -H \"Content-Type: application/json\" -d $json_payload";

            if ($post_response->is_success) {
                if($debug) { print "\t\t\tAdded interface " . $new_interface->{mac_address} . " to NetBox.\n"; }
            } else {
                warn "Failed to add interface: ", $post_response->status_line, "\n";
                print "Response content: ", $post_response->decoded_content, "\n";
            }
        }
    }

    foreach my $netbox_if_id (keys %netbox_if) {
        my $netbox_if = $netbox_if{$netbox_if_id};
        my $found_match = 0;

        foreach my $new_interface (@$new_interfaces) {
            if ($netbox_if->{name} eq $new_interface->{name} && lc($netbox_if->{mac_address}) eq lc($new_interface->{mac_address})) {
                $found_match = 1;
                last;
            }
        }

        unless ($found_match) {
            if($debug) { print "\t\tInterface $netbox_if->{name} not found in new interfaces. Removing from NetBox...\n"; }
            #my $delete_response = $netbox_ua->delete("$netbox_api_url$netbox_virt_int_url$netbox_if_id");

            #if ($delete_response->is_success) {
            #    print "Interface $netbox_if->{name} successfully removed from NetBox.\n";
            #} else {
            #    warn "Failed to delete interface: ", $delete_response->status_line, "\n";
            #}
        }
    }
}

sub vm_ip_int {
    my ($vm_name, $ipaddr, $iface) = @_;   
    my $networkaddr;

    my $vm_int = get_vm_int($vm_name,$iface);
    if(!defined($vm_int)) { 
        warn "No valid interface found\n"; 
        return; 
    }

    $ipaddr =~ s/%[^%]*$//;
    if($ipaddr =~ /:/) {
        $ipaddr =~ s/\./:/g;
    }

    my $netmask = '0';

    if ($netmask !~ /^(?:\d{1,3})$/ || $netmask < 1 || $netmask > 128) {
        if($ipaddr =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/) {    
            $netmask = '32';
        } elsif($ipaddr =~ /:/) {
            $netmask = '128';
        } else {
            print "\t\tnot sure on the netmask, moving on : $ipaddr\n";
            return;
        }
    }

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
            warn "Failed to add IP $networkaddr on $vm_name interface $vm_int: ", $post_response->status_line, "\n";
        }
    } else {
        if($debug) { print "\t\t\tIP already exists in the DB.\n"; }
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

sub get_vm_int {
    my ($vm_name,$ifname) = @_; 
    my $netbox_virt_int_url = "virtualization/interfaces/";

    my $netbox_id_response = $netbox_ua->get("$netbox_api_url$netbox_virt_int_url?virtual_machine=$vm_name&name=$ifname");
    die "Failed to get NetBox VM data: ", $netbox_id_response->status_line unless $netbox_id_response->is_success;
    my $netbox_id_data = decode_json($netbox_id_response->decoded_content);

    return $netbox_id_data->{results}[0]->{id} if @{$netbox_id_data->{results}};
    return undef;
}

sub HelpMessage {

  print "NAME\n";
  print "\n";
  print "xenserver / netbox automation \n";
  print "\n";
  print "SYNOPSIS\n";
  print "\n";
  print "  --cluster,-c     Specify the cluster to test against (required) \n";
  print "                                 \n";
  print "  --query,-q       Define a specific URL, used to query a specific server. \n";
  print "  --username,-u    Define a specific username, overwrite the hard coded account. \n";
  print "  --password,-p    Define a specific password, overwrite the hard coded account. \n";
  print "  --help,-?    Print this help\n";
  print "\n\n";
  print " EXAMPLE";
  print " query all systems on madscience and put them into netbox";
  print " xen-automation.pl -c madscience\n";
  print " \n";
  print " \n";
  print "\n";
  print "VERSION\n";
  print "\n";
  print "1.04 - 3/14/2025\n";
  print "\n";
  exit;
}