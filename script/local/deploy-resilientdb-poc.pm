package deploy_resilientdb_poc;

use strict;
use warnings;

use File::Copy;

use Minion::Run::Simd;


my $FLEET = $_;
my %PARAMS = @_;
my $RUNNER = $PARAMS{RUNNER};
my $DIEM_PATH = $ENV{MINION_SHARED} . '/resilientdb_poc';
my $ROLE_PATH = $DIEM_PATH . '/behaviors.txt';

my $DEPLOY_ROOT = 'deploy/resilientdb_poc';       # Where the files are deployed on

my $MINION_PRIVATE = $ENV{MINION_PRIVATE};  # Where to store local private data

my $TRANSACTION_CONFIG_NAME = 'transaction_server.config';
my $MINING_CONFIG_NAME = 'mining_server.config';
my $TRANSACTION_CONFIG_PATH = $MINION_PRIVATE . '/' . $TRANSACTION_CONFIG_NAME;
my $MINING_CONFIG_PATH = $MINION_PRIVATE . '/' . $MINING_CONFIG_NAME;

sub get_nodes 
{
  my ($path) = @_;
  my (%nodes, $node, $fh, $line, $ip, $base_port, $id, $nid, $number, $last_ip, $type, $worker, $assigned);

  $type="replica";
  $base_port=30001;
  $nid=1;

  if (!open($fh, '<', $path)) {
    die ("cannot open '$path' : $!");
  }

  while (defined($line = <$fh>)) {
    chomp($line);
    ($ip, $number) = split(':', $line);
    $last_ip = $ip;
    $node = $nodes{$ip};
    $number=1;

    if (defined($node)) {
      $node->{'number'} = 1;
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

  $nodes{$last_ip}->{'type'} = "client";
  
  foreach $ip (keys(%$nodes)) {
          $id  = $nodes->{$ip}->{'id'};

	  if( $id == ($nid-1)/2+1 ){
		  $nodes{$ip}->{'type'} = "client";
	  } 
	  if( $id > ($nid-1)/2+1) {
		  $nodes{$ip}->{'type'} = "poc";
	  }
    }

  return \%nodes;
}

sub generate_setup
{
    my ($nodes, $target) = @_;
    my ($ifh, $ofh, $line, $ip, $worker, %groups, $tags, $client_ip, $client_port, $poc_client_ip, $poc_client_port);

  
    printf("generate setup $target");

    foreach $ip (keys(%$nodes)) {
          $line = sprintf("%s:%d", $ip, $nodes->{$ip}->{'port'});
          $tags = $nodes->{$ip}->{'worker'}->region();
          if($nodes->{$ip}->{'type'} eq "client"){
            $client_ip=$ip;
            $client_port=int($nodes->{$ip}->{'port'});
          }
          if($nodes->{$ip}->{'type'} eq "poc"){
            $poc_client_ip=$ip;
            $poc_client_port=int($nodes->{$ip}->{'port'});
          }
          push(@{$groups{$tags}}, $line);
    }

    if (!open($ofh, '>', $target)) {
        return 0;
    }

    printf($ofh "interface: \"resilientdb-poc\"\n");
    printf($ofh "\n");
    printf($ofh "parameters:\n");
	  printf($ofh "  client_ip: \"$client_ip\"\n");
	  printf($ofh "  client_port: \"$client_port\"\n");
	  printf($ofh "  poc_client_ip: \"$poc_client_ip\"\n");
	  printf($ofh "  poc_client_port: \"$poc_client_port\"\n");
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
        printf("gen config ip $ip, type $type\n");
        if($type eq "client"){
          next;
        }
	if($type eq "poc"){
		printf($mfh "\t\treplica_info: {\n");
		printf($mfh "\t\t\tid: $id,\n");
		printf($mfh "\t\t\tip: \"$ip\",\n");
		printf($mfh "\t\t\tport: %d\n",$port);
		printf($mfh "\t\t},\n");
	}else {
		printf($ofh "\t\treplica_info: {\n");
		printf($ofh "\t\t\tid: $id,\n");
		printf($ofh "\t\t\tip: \"$ip\",\n");
		printf($ofh "\t\t\tport: %d\n",$port);
		printf($ofh "\t\t},\n");
	}
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

      if ($number != 1){
        die ("failed to prepare config, only support 1 ip 1 server.");
      }

      if($type == "poc") {
	      $proc = $worker->send([ $server_config, $mining_config ], TARGET => $DEPLOY_ROOT);
	      if ($proc->wait() != 0) {
		die ("failed to prepare avalanche workers");
	      }
      } else {
	      $proc = $worker->send([ $server_config ], TARGET => $DEPLOY_ROOT);
	      if ($proc->wait() != 0) {
		die ("failed to prepare avalanche workers");
	      }
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

      if($type == "poc"){
	      $type = "replica"
      }

      $proc = $RUNNER->run($worker, [ 'deploy-resilientdb-worker','generate', $ip, $port, $type, $id ]);
      if ($proc->wait() != 0) {
        die ("failed to generate keys");
      }
    }
    return 1;
}

sub deploy_resilientdb_poc
{
  my ($simd, $fh, $nodes, $line, $ip, %workers, $worker, $assigned, @workers, $proc);

  if (!(-e $ROLE_PATH)) {
    return 1;
  }

  $nodes = get_nodes($ROLE_PATH);

  if (!build_config($TRANSACTION_CONFIG_PATH, $MINING_CONFIG_PATH, $nodes)) {
    die ("cannot generate node file '$TRANSACTION_CONFIG_PATH' : $!");
  }

# Prepare deployment for all nodes.
# Like mkdir dictories.
  @workers = map { $_->{'worker'} } values(%$nodes);
  $proc = $RUNNER->run(\@workers, [ 'deploy-resilientdb-poc-worker','prepare' ]);
  if ($proc->wait() != 0) {
    die ("failed to prepare avalanche workers");
  }

# Send configs to all nodes
  if (!dispatch_config($TRANSACTION_CONFIG_PATH, $MINING_CONFIG_PATH, $nodes)) {
    die ("cannot dispatch node file '$TRANSACTION_CONFIG_PATH' : $!");
  }

# Generate pri-pub keys
  if (!generate_keys($TRANSACTION_CONFIG_PATH, $MINING_CONFIG_PATH, $nodes)) {
    die ("cannot dispatch node file '$TRANSACTION_CONFIG_PATH' : $!");
  }

# Generate setup.yaml for primary
  if (!generate_setup($nodes, $DIEM_PATH. '/setup.yaml')){
    die ("cannot generate setup file '$DIEM_PATH' : $!");
  }
  return 1;
}


deploy_resilientdb_poc();
__END__
