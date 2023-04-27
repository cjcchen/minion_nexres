package deploy_algorand_poc;

use strict;
use warnings;

use List::Util qw(sum);

use Minion::StaticFleet;
use Minion::System::Pgroup;


my $FLEET = $_;
my %PARAMS = @_;
my $RUNNER = $PARAMS{RUNNER};

my $NODE_LIST_PATH = $ENV{MINION_SHARED} . '/algorand-nodes';

my $NETWORK_TEMPLATE_NAME = 'network.json';
my $NETWORK_TEMPLATE_PATH = $ENV{MINION_PRIVATE} . '/' .$NETWORK_TEMPLATE_NAME;

my $NODEFILE_NAME = 'nodes';
my $NODEFILE_PATH = $ENV{MINION_PRIVATE} . '/' . $NODEFILE_NAME;

my $PEER_TCP_PORT   = 7000;
my $CLIENT_TCP_PORT = 9000;

my $NETWORK_NAME = 'network';
my $NETWORK_PATH = $ENV{MINION_PRIVATE} . '/' . $NETWORK_NAME;

my $ALGORAND_PATH = $ENV{MINION_SHARED} . '/algorand_poc';

my $POC_DEPLOY_ROOT = 'deploy/poc';       # Where the files are deployed on
my $MINION_PRIVATE = $ENV{MINION_PRIVATE};  # Where to store local private data
my $TRANSACTION_CONFIG_NAME = 'transaction_server.config';
my $MINING_CONFIG_NAME = 'mining_server.config';
my $TRANSACTION_CONFIG_PATH = $MINION_PRIVATE . '/' . $TRANSACTION_CONFIG_NAME;
my $MINING_CONFIG_PATH = $MINION_PRIVATE . '/' . $MINING_CONFIG_NAME;


# Extract from the given $path the Algorand nodes.
#
# Return: { $ip => { 'worker' => $worker
#                  , 'number' => $number
#                  }
#         }
#
#   where $ip is an IPv4 address, $worker is a Minion::Worker object and
#   $number indicates the number of instances to deploy on $worker.
#
sub get_nodes
{
    my ($path) = @_;
    my (%nodes, $node, $fh, $line, $ip, $base_port, $id, $nid, $number, $last_ip, $type, $worker, $assigned);


    print("path: $path");
    $type="chain";
    $base_port=30001;
    $nid=1;

    if (!open($fh, '<', $path)) {
	die ("cannot open '$path' : $!");
    }

    while (defined($line = <$fh>)) {
      chomp($line);
      ($ip, $number) = split(':', $line);

      $node = $nodes{$ip};

      print("get ip??:",$ip, $type);

      if (defined($node)) {
        $node->{'number'} += $number;
        next;
      }

      $assigned = undef;

      foreach $worker ($FLEET->members()) {
        if ($worker->can('public_ip') && ($worker->public_ip() eq $ip)) {
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

      $nodes{$ip} = {
        'worker' => $assigned,
        'number' => $number,
          'port' => $base_port,
        'type' => $type,
        'id' => $nid
      };
      $base_port=$base_port+1;
      $nid=$nid+1;
    }

    close($fh);

    return \%nodes;
}

# Return the sorted IPs of Algorand full or client nodes from the actors as
# returned by `get_actors()` and a role.
# If an actor has an instance number greater than 1 then its IP is repeated as
# many times.
#
# Return: [ $ip , ... ]
#
sub get_actors_ip_instances
{
    my ($actors, $role) = @_;
    my (@ips, $ip, $actor, $number, $i);

    while (($ip, $actor) = each(%{$actors->{$role}})) {
	$number = $actor->[1];
	for ($i = 0; $i < $number; $i++) {
	    push(@ips, $ip);
	}
    }

    return [ sort { $a cmp $b } @ips ];
}

# Return the workers of Algorand full or client nodes from the actors as
# returned by `get_actors()` and a role.
# If an actor has an instance number greater than 1 then the corresponding
# worker is repeated as many times.
# The workers appear sorted by their IP.
#
# Return: [ $worker , ... ]
#
sub get_actors_worker_instances
{
    my ($actors, $role) = @_;
    my (@workers, $ip, $actor, $worker, $number, $i);

    foreach $ip (sort { $a cmp $b } keys(%{$actors->{$role}})) {
	$actor = $actors->{$role}->{$ip};
	$worker = $actor->[0];
	$number = $actor->[1];

	for ($i = 0; $i < $number; $i++) {
	    push(@workers, $worker);
	}
    }

    return \@workers;
}

sub build_network_template
{
    my ($path, $nodes) = @_;
    my ($nodenum, $walletnum);
    my ($fh, $share, $rem, $stake, $name, $sep, $i, $worker);

    $nodenum = sum(map { $_->{'number'} } values(%$nodes));
    $walletnum = $nodenum;

    $share = sprintf("%.2f", 100.0 / $walletnum);
    $rem = 100.0 - ($share * $walletnum);

    if (!open($fh, '>', $path)) {
	die ("cannot create algorand network template '$path' : $!");
    }

    printf($fh "%s", <<"EOF");
{
    "Genesis": {
	"NetworkName": "PrivateNet",
	"Wallets": [
EOF

    $sep = '';

    for ($i = 0; $i < $walletnum; $i++) {
	if ($i == 0) {
	    $stake = $share + $rem;
	} else {
	    $stake = $share;
	}

	printf($fh "%s%s", $sep, <<"EOF");
	    {
		"Name": "wallet_$i",
		"Stake": $stake,
		"Online": true
	    }
EOF
	$sep = "\t    ,\n";
    }

    printf($fh "%s", <<"EOF");
	]
    }
    ,
    "Nodes": [
EOF

    $sep = '';

    for ($i = 0; $i < $walletnum; $i++) {
	$name = "n" . $i;

	printf($fh "%s%s", $sep, <<"EOF");
	{
	    "Name": "$name",
	    "IsRelay": true,
	    "Wallets": [
		{
		    "Name": "wallet_$i",
		    "ParticipationOnly": false
		}
            ]
	}
EOF

	$sep = "\t,\n";
    }

    printf($fh "%s", <<"EOF");
    ]
}
EOF

    close($fh);
}

sub build_nodefile
{
    my ($path, $nodes) = @_;
    my ($fh, $ip, $i);

    if (!open($fh, '>', $path)) {
	die ("cannot create algorand nodefile '$path' : $!");
    }

    foreach $ip (keys(%$nodes)) {

      for ($i = 0; $i < $nodes->{$ip}->{'number'}; $i++) {
        printf($fh "%s:%d:%d\n", $ip, $PEER_TCP_PORT + $i,
            $CLIENT_TCP_PORT + $i);

        printf("%s:%d:%d\n", $ip, $PEER_TCP_PORT + $i,
            $CLIENT_TCP_PORT + $i);
      }
    }

    close($fh);
}

sub dispatch
{
    my ($nodes, $network) = @_;
    my ($ip, $i, $done, @paths, @procs, $proc, @statuses);

    $done = 0;

    foreach $ip (keys(%$nodes)) {
      @paths = ();

      for ($i = 0; $i < $nodes->{$ip}->{'number'}; $i++) {
        push(@paths, $NETWORK_PATH . '/n' . ($done + scalar(@paths)));
      }

      $proc = $nodes->{$ip}->{'worker'}->send(
          [ @paths ],
          TARGET => 'deploy/algorand/'
          );
      push(@procs, $proc);

      $done += scalar(@paths);
    }

    @statuses = Minion::System::Pgroup->new(\@procs)->waitall();

    if (grep { $_->exitstatus() != 0 } @statuses) {
	die ("cannot dispatch algorand network to workers");
    }
}

sub generate_setup
{
    my ($nodes, $target) = @_;
    my ($ifh, $ofh, $line, $ip, $i, $port, $worker, %groups, $tags, $poc_client_ip, $poc_client_port);

	foreach $ip (keys(%$nodes)) {
	for ($i = 0; $i < $nodes->{$ip}->{'number'}; $i++) {
		$line = sprintf("%s:%d", $ip, $CLIENT_TCP_PORT + $i);
		$tags = $nodes->{$ip}->{'worker'}->region();
		push(@{$groups{$tags}}, $line);
	}
      $poc_client_ip = $ip;
      $poc_client_port = $nodes->{$ip}->{'port'};
    }

    if (!open($ofh, '>', $target)) {
	return 0;
    }

    printf($ofh "interface: \"algorand-poc\"\n");
    printf($ofh "\n");
    printf($ofh "parameters:\n");
	printf($ofh "  confirm: \"pollblk\"\n");
  #printf($ofh "  poc_client_ip: 172.31.27.40\n");
  printf($ofh "  poc_client_ip: $poc_client_ip\n");
  #printf($ofh "  poc_client_port: 30004\n");
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


sub deploy_poc
{
    my ($simd, $fh, $line, $nodes, $ip, %workers, $worker, $assigned, @workers, $proc, $type);

    if (!(-e $NODE_LIST_PATH)) {
      print(" ============= deploy algorand ============= ");
      return 1;
    }

    $nodes = get_nodes($NODE_LIST_PATH);

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

sub deploy_algorand
{
  print(" ============= deploy algorand ============= ");
    my ($nodes, $genworker, $ret);
    my ($i, $proc, @procs, @statuses, $ip, $worker);

    if (!(-e $NODE_LIST_PATH)) {
      print(" ============= deploy algorand ============= ");
      return 1;
    }

    $nodes = get_nodes($NODE_LIST_PATH);

    # Build the global information files necessary to generate the Algorand
    # testnet.
    #

    build_network_template($NETWORK_TEMPLATE_PATH, $nodes);

    build_nodefile($NODEFILE_PATH, $nodes);

    # The testnet generation involves Algorand binaries. It is thus necessary
    # to send the information files to a worker with the installed binaries for
    # it to generate the testnet and fetch back the generated network.
    #

    $genworker = ($FLEET->members())[0];

      $proc = $RUNNER->run(
          $FLEET,
          [ 'deploy-algorand-worker', 'prepare' ]
          );

      if ($proc->wait() != 0) {
        die ("failed to prepare algorand workers");
      }

    $proc = $genworker->send(
	[ $NETWORK_TEMPLATE_PATH, $NODEFILE_PATH ],
	TARGET => 'deploy/algorand/'
	);
    if ($proc->wait() != 0) {
	die ("cannot send algorand network template to worker");
    }

    $proc = $RUNNER->run(
	$genworker,
	[ 'deploy-algorand-worker', 'generate', $NETWORK_TEMPLATE_NAME,
	  $NODEFILE_NAME ]
	);
    if ($proc->wait() != 0) {
	die ("failed to generate algorand testnet");
    }

    $proc = $genworker->recv(
	[ 'deploy/algorand/' . $NETWORK_NAME . '.tar.gz' ],
	TARGET => $ENV{MINION_PRIVATE}
	);
    if ($proc->wait() != 0) {
	die ("cannot receive algorand testnet from worker");
    }
	$proc = $genworker->recv(
	[ 'deploy/algorand/' . 'accounts.yaml' ],
	TARGET => $ALGORAND_PATH . '/accounts.yaml'
	);
    if ($proc->wait() != 0) {
	die ("cannot receive algorand accounts from worker");
    }

    $genworker->execute(
	[ 'rm', '-rf',
  'deploy/algorand/' . $NETWORK_NAME . '.tar.gz',
  'deploy/algorand/' . 'accounts.yaml',
  'deploy/algorand/' . $NETWORK_TEMPLATE_NAME,
 'deploy/algorand/' . $NODEFILE_NAME ]
	)->wait();


    # Now this control node can dispatch the necessary information to every
    # nodes.
    #

  print("tar $ENV{MINION_PRIVATE} . '/' . $NETWORK_NAME . '.tar.gz'");

    system('tar', '--directory=' . $ENV{MINION_PRIVATE}, '-xzf',
	   $ENV{MINION_PRIVATE} . '/' . $NETWORK_NAME . '.tar.gz');

	generate_setup($nodes, $ALGORAND_PATH . '/setup.yaml');

    dispatch($nodes, $NETWORK_PATH);


    # Cleanup before to finish.
    #

    unlink($NODE_LIST_PATH);

    return 1;
}

deploy_poc();
deploy_algorand();
__END__
