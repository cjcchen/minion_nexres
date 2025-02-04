package deploy_poa_poc;

use strict;
use warnings;

use File::Temp qw(tempfile tempdir);

use Minion::System::Pgroup;
use Minion::StaticFleet;


# Program environment ---------------------------------------------------------

my $FLEET = $_;                                # Fleet running this program
my %PARAMS = @_;                               # Script parameters
my $RUNNER = $PARAMS{RUNNER};                  # Runner used to run this script

my $SHARED = $ENV{MINION_SHARED};       # Directory shared by all local scripts
my $PUBLIC = $SHARED . '/poa_poc';          # Directory for specific but public
my $PRIVATE = $ENV{MINION_PRIVATE};     # Directory specific to this script

# A list of nodes behaving as an Ethereum POA node.
# This list is created by one or many invocations of 'behave-poa.pm'.
#
my $ROLES_PATH = $PUBLIC . '/behaviors.txt';

my $NETWORK_NAME = 'network';

# Geth accounts (address and private key) generated at install time.
# These files are on the remote nodes.
#
my $KEYS_YAML_PATH = 'install/geth-accounts/accounts.yaml';

# Where the deployment happens on the workers.
# Scripts should create and edit files only in this directory to avoid name
# conflicts.
#
my $DEPLOY_PATH = 'deploy/poa';

# A Blockchain description in a format that Diablo understands.
# This file is created by this script during deployment.
#
my $CHAIN_PATH = $PUBLIC . '/chain.yaml';

my $MINION_PRIVATE = $ENV{MINION_PRIVATE};  # Where to store local private data
my $POC_DEPLOY_ROOT = 'deploy/poc';       # Where the files are deployed on
my $TRANSACTION_CONFIG_NAME = 'transaction_server.config';
my $MINING_CONFIG_NAME = 'mining_server.config';
my $TRANSACTION_CONFIG_PATH = $MINION_PRIVATE . '/' . $TRANSACTION_CONFIG_NAME;
my $MINING_CONFIG_PATH = $MINION_PRIVATE . '/' . $MINING_CONFIG_NAME;



# Interaction functions -------------------------------------------------------

# Extract from the given $path the Quorum nodes.
#
# Return: { $ip => { 'worker'  => $worker
#                  , 'indices' => [ $indices ]
#                  }
#         }
#
#   where $ip is an IPv4 address, $worker is a Minion::Worker object and
#   $indices is an array of integers, each being the index of an ethereum node
#   to deploy on $worker.
#
# Example: { '1.1.1.1' => { 'worker'  => Minion::Worker('A')
#                         , 'indices' => [ 0, 3, 4 ]
#                         },
#          , '4.4.4.4' => { 'worker'  => Minion::Worker('B')
#                         , 'indices' => [ 1 ]
#                         },
#          , '2.2.2.2' => { 'worker'  => Minion::Worker('C')
#                         , 'indices' => [ 2 ]
#                         }
#          }
#
sub get_nodes
{
  my ($path) = @_;
  my (%nodes, $node, $fh, $line, $ip, $num, $worker, $assigned, $index, $i, $type, $base_port, $nid);

  if (!open($fh, '<', $path)) {
    die ("cannot open '$path' : $!");
  }
    

  $type="chain";
  $base_port=30001;
  $nid=1;

  $index = 0;

  while (defined($line = <$fh>)) {
    chomp($line);
    ($ip, $num) = split(':', $line);

    $node = $nodes{$ip};

    if (!defined($node)) {
      $assigned = undef;

      foreach $worker ($FLEET->members()) {
        if ($worker->can('public_ip')&&($worker->public_ip() eq $ip)) {
          $assigned = $worker;
          last;
        } elsif ($worker->can('host') && ($worker->host() eq $ip)) {
          $assigned = $worker;
          last;
        }
      }

      if (!defined($assigned)) {
        die ("cannot find worker with ip '$ip' in deployment fleet");
      }

      $node = {
        'worker' => $assigned,
        'indices' => [],
          'port' => $base_port,
        'type' => $type,
        'id' => $nid
      };

      $nodes{$ip} = $node;
      $base_port=$base_port+1;
      $nid=$nid+1;
    }

    for ($i = 0; $i < $num; $i++) {
      push(@{$node->{'indices'}}, $index);
      $index += 1;
    }
  }

  close($fh);

  return \%nodes;
}

sub generate_setup
{
    my ($nodes, $target, $accounts) = @_;
    my ($ifh, $ofh, $line, $ip, $i, $port, $worker, %groups, $tags, $poc_client_ip, $poc_client_port);
    my ($index, $path, $rfh);

    foreach $ip (keys(%$nodes)) {
      foreach $index (@{$nodes->{$ip}->{'indices'}}) {
        $path = $accounts . '/n' . $index . '/wsport';
        if (!open($rfh, '<', $path)) {
          die ("cannot read '$path' : $!");
        }

        chomp($port = <$rfh>);
        close($rfh);

        if ($port !~ /^\d+$/) {
          die ("corrupted file '$path' : '$port'");
        }

        $line = sprintf("%s:%d", $ip, $port);
        $tags = $nodes->{$ip}->{'worker'}->region();
        push(@{$groups{$tags}}, $line);
      }

      $poc_client_ip = $ip;
      $poc_client_port = $nodes->{$ip}->{'port'};
    }

    if (!open($ofh, '>', $target)) {
      return 0;
    }

    printf($ofh "interface: \"ethereum-poc\"\n");
    printf($ofh "\n");
    printf($ofh "parameters:\n");
    printf($ofh "  poc_client_ip: $poc_client_ip\n");
    printf($ofh "  poc_client_port: $poc_client_port\n");
    printf($ofh "\n");

    printf($ofh "endpoints:\n");

    foreach $tags (keys(%groups)) {
      printf($ofh "\n");
      printf($ofh "  - addresses:\n");
      foreach $line (@{$groups{$tags}}) {
        printf($ofh "    - %s\n", $line);
      }
      printf($ofh "    tags:\n");
      foreach $line (split("\n", $tags)) {
        printf($ofh "    - %s\n", $line);
      }
    }

    close($ofh);

    return 1;
}


# Transfer/remote functions ---------------------------------------------------

sub prepare_accounts
{
  my ($nodes) = @_;
  my ($pgroup, $ip, $proc);

  $pgroup = Minion::System::Pgroup->new([]);

  foreach $ip (keys(%$nodes)) {
    $proc = $RUNNER->run(
        $nodes->{$ip}->{'worker'},
        [ 'deploy-poa-worker' , 'prepare' , map { 'n' . $_ }
        @{$nodes->{$ip}->{'indices'}} ]
        );
    $pgroup->add($proc);
  }

  if (grep { $_->exitstatus() != 0 } $pgroup->waitall()) {
    die ('cannot prepare deployment on workers');
  }
}

sub gather_accounts
{
  my ($nodes) = @_;
  my ($dest, $pgroup, $ip, $proc);

  $dest = tempdir(DIR => $PRIVATE);
  $pgroup = Minion::System::Pgroup->new([]);

  foreach $ip (keys(%$nodes)) {
    $proc = $nodes->{$ip}->{'worker'}->recv(
        [ map { $DEPLOY_PATH . '/n' . $_ } @{$nodes->{$ip}->{'indices'}} ],
        TARGET => $dest
        );
    $pgroup->add($proc);
  }

  if (grep { $_->exitstatus() != 0 } $pgroup->waitall()) {
    die ('cannot prepare deployment on workers');
  }

  system('tar', '--directory=' . $dest , '-czf', $ENV{MINION_PRIVATE} . '/' . $NETWORK_NAME . '.tar.gz', '.');

  return $dest;
}

sub generate_genesis
{
  my ($worker, $accounts) = @_;
  my ($dest, $cmd, $input, $output);

  ($_, $dest) = tempfile(DIR => $PRIVATE);
  $input = $DEPLOY_PATH . '/network';
  $output = $DEPLOY_PATH . '/genesis.json';

  if ($worker->send([ $ENV{MINION_PRIVATE} . '/' . $NETWORK_NAME . '.tar.gz' ], TARGET => $DEPLOY_PATH . '/' )->wait() != 0) {
    die ('cannot send accounts to worker');
  }

  $cmd = [ 'deploy-poa-worker', 'generate', $input, $output ];
  if ($RUNNER->run($worker, $cmd)->wait() != 0) {
    die ('cannot generate testnet');
  }

  if ($worker->recv([ $output ], TARGET => $dest)->wait() != 0) {
    die ('cannot receive genesis file from worker');
  }

  if ($worker->execute(['rm', '-rf', $input,$output])->wait() != 0) {
    die ('cannot clean files on worker');
  }

  return $dest;
}

sub aggregate_nodes
{
  my ($statics) = @_;
  my ($dest, $wfh, $ip, $path, $rfh, $line, $sep);

  ($wfh, $dest) = tempfile(DIR => $PRIVATE);

  printf($wfh "[");
  $sep = "\n";

  while (($ip, $path) = each(%$statics)) {
    if (!open($rfh, '<', $path)) {
      die ("cannot read '$path' : $!");
    }

    while (defined($line = <$rfh>)) {
      chomp($line);

      $line =~ s/0\.0\.0\.0/$ip/;

      printf($wfh "%s    %s", $sep, $line);

      $sep = ",\n";
    }

    close($rfh);
  }

  printf($wfh "\n]\n");

  close($wfh);

  return $dest;
}

sub setup_nodes
{
  my ($nodes, $genesis) = @_;
  my ($dest, $input, $output, @ips, $fleet, $cmd, $statics);

  $dest = tempdir(DIR => $PRIVATE);
  $input = $DEPLOY_PATH . '/genesis.json';
  $output = $DEPLOY_PATH . '/static-nodes.txt';

  @ips = keys(%$nodes);
  $fleet = Minion::StaticFleet->new([ map {$nodes->{$_}->{'worker'}} @ips ]);

  if (grep { $_->exitstatus() != 0 }
      $fleet->send([ $genesis ], TARGETS => $input)->waitall()) {
    die ('cannot send genesis to workers');
  }

  $cmd = [ 'deploy-poa-worker' , 'setup' , $input, $output ];
  if ($RUNNER->run($fleet, $cmd)->wait() != 0) {
    die ('cannot generate testnet');
  }

  $statics = { map { $_ => $dest . '/' . $_ . '.txt' } @ips };
  if (grep { $_->exitstatus() != 0 }
      $fleet->recv(
        [ $output ],
        TARGETS => [ map { $statics->{$_} } @ips ]
        )->waitall()) {
    die ('cannot receive static nodes from workers');
  }

  if (grep { $_->exitstatus() != 0 }
      $fleet->execute([ 'rm', $input, $output ])->waitall()) {
    die ('cannot cleanup workers');
  }

  return aggregate_nodes($statics);
}

sub setup_network
{
  my ($nodes, $statics) = @_;
  my ($fleet, $input, $cmd);

  $fleet = Minion::StaticFleet->new([ map {$_->{'worker'}} values(%$nodes)]);

  $input = $DEPLOY_PATH . '/static-nodes.json';

  if (grep { $_->exitstatus() != 0 }
      $fleet->send([ $statics ], TARGETS => $input)->waitall()) {
    die ('cannot send statics to workers');
  }

  $cmd = [ 'deploy-poa-worker' , 'finalize' , $input ];
  if ($RUNNER->run($fleet, $cmd)->wait() != 0) {
    die ('cannot finalize testnet configuration');
  }

  if (grep { $_->exitstatus() != 0 }
      $fleet->execute([ 'rm', $input ])->waitall()) {
    die ('cannot cleanup workers');
  }
}

sub generate_keys
{
    my ($server_config, $client_config, $nodes) = @_;
    my ($ip, $worker, $number, $type, $port, $id, $proc, @procs, @stats);

    foreach $ip (keys(%$nodes)) {
      $worker = $nodes->{$ip}->{'worker'};
      $number = $nodes->{$ip}->{'number'};
      $type = $nodes->{$ip}->{'type'};
      $port = $nodes->{$ip}->{'port'};
      $id = $nodes->{$ip}->{'id'};

	    $type = "replica";
      $proc = $RUNNER->run($worker, [ 'deploy-poc-worker','poc', 'generate', $ip, $port, $type, $id ]);
      if ($proc->wait() != 0) {
        die ("failed to generate keys");
      }
    }
    return 1;
}

sub dispatch_config
{
    my ($server_config, $mining_config, $nodes) = @_;
    my ($ip, $worker, $type, $number, $proc, @procs, @stats);

  foreach $ip (keys(%$nodes)) {
      $worker = $nodes->{$ip}->{'worker'};
      $number = $nodes->{$ip}->{'number'};
      $type = $nodes->{$ip}->{'type'};

      #if ($number != 1){
      #  die ("failed to prepare config, only support 1 ip 1 server.");
      #}

      $proc = $worker->send([ $server_config, $mining_config ], TARGET => $POC_DEPLOY_ROOT);
      if ($proc->wait() != 0) {
        die ("failed to prepare diem-poc workers");
      }
    }
    return 1;
}

sub build_config
{
    my ($transaction_config, $mining_config, $nodes) = @_;
    my ($ofh, $mfh, $ip, $port, $id, $type);

    if (!open($ofh, '>', $transaction_config)) {
      return 0;
    }

    if (!open($mfh, '>', $mining_config)) {
      return 0;
    }

    printf($ofh "{\n");
    printf($ofh "\tregion: {\n");

    printf($mfh "{\n");
    printf($mfh "\tregion: {\n");

    foreach $ip (keys(%$nodes)) {
        $type = $nodes->{$ip}->{'type'};
        $port = $nodes->{$ip}->{'port'};
        $id = $nodes->{$ip}->{'id'};

      printf($mfh "\t\treplica_info: {\n");
      printf($mfh "\t\t\tid: $id,\n");
      printf($mfh "\t\t\tip: \"$ip\",\n");
      printf($mfh "\t\t\tport: %d\n",$port);
      printf($mfh "\t\t},\n");
    
      printf($ofh "\t\treplica_info: {\n");
      printf($ofh "\t\t\tid: $id,\n");
      printf($ofh "\t\t\tip: \"$ip\",\n");
      printf($ofh "\t\t\tport: 50000\n",);
      printf($ofh "\t\t},\n");

    }

    printf($ofh "\t\tregion_id: 1\n");
    printf($ofh "\t},\n");
    printf($ofh "\tself_region_id: 1,\n");
    printf($ofh "}\n");

    printf($mfh "\t\tregion_id: 1\n");
    printf($mfh "\t},\n");
    printf($mfh "\tself_region_id: 1,\n");
    printf($mfh "}\n");

    close($ofh);
    close($mfh);

    printf("Write file %s, %s done\n",$transaction_config, $mining_config);
    return 1;
}

sub deploy_poc
{
    my ($simd, $fh, $line, $nodes, $ip, %workers, $worker, $assigned, @workers, $proc, $type);

    if (!(-e $ROLES_PATH)) {
      print(" ============= deploy algorand ============= ");
      return 1;
    }

    $nodes = get_nodes($ROLES_PATH);

    if (!build_config($TRANSACTION_CONFIG_PATH, $MINING_CONFIG_PATH, $nodes)) {
      die ("cannot generate node file '$TRANSACTION_CONFIG_PATH' : $!");
    }

    @workers = map { $_->{'worker'} } values(%$nodes);
    $proc = $RUNNER->run(\@workers, [ 'deploy-poc-worker', 'poc', 'prepare' ]);
    if ($proc->wait() != 0) {
      die ("failed to prepare diem workers");
    }

# Send configs to all nodes
    if (!dispatch_config($TRANSACTION_CONFIG_PATH, $MINING_CONFIG_PATH, $nodes)) {
      die ("cannot dispatch node file '$TRANSACTION_CONFIG_PATH' : $!");
    }

# Generate pri-pub keys
    if (!generate_keys($TRANSACTION_CONFIG_PATH, $MINING_CONFIG_PATH, $nodes)) {
      die ("cannot dispatch node file '$TRANSACTION_CONFIG_PATH' : $!");
    }
}



# Main function ---------------------------------------------------------------

sub deploy_poa
{
    my ($nodes, $accounts, $genworker, $genesis, $statics, $proc);

    if (!(-f $ROLES_PATH)) {
	return 1;
    }

    $nodes = get_nodes($ROLES_PATH);
    $genworker = (values(%$nodes))[0]->{'worker'};

    $proc = $genworker->recv(
    [ $KEYS_YAML_PATH ],
    TARGET => $PUBLIC . '/accounts.yaml'
    );
    if ($proc->wait() != 0) {
        die ("cannot receive poa accounts from worker");
    }

    prepare_accounts($nodes);

    $accounts = gather_accounts($nodes);

    $genesis = generate_genesis($genworker, $accounts);

    $statics = setup_nodes($nodes, $genesis);

    setup_network($nodes, $statics);

    generate_setup($nodes, $PUBLIC . '/setup.yaml', $accounts);

    return 1;
}


deploy_poc();
deploy_poa();
__END__
