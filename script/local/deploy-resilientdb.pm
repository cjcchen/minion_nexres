package deploy_resilientdb;

use strict;
use warnings;

use File::Copy;

use Minion::Run::Simd;


my $FLEET = $_;
my %PARAMS = @_;
my $RUNNER = $PARAMS{RUNNER};
my $DIEM_PATH = $ENV{MINION_SHARED} . '/resilientdb';
my $ROLE_PATH = $DIEM_PATH . '/behaviors.txt';

my $DEPLOY_ROOT = 'deploy/resilientdb';       # Where the files are deployed on

my $MINION_PRIVATE = $ENV{MINION_PRIVATE};  # Where to store local private data

my $SERVER_CONFIG_NAME = 'server.config';
my $PROXY_CONFIG_NAME = 'proxy.config';
my $SERVER_CONFIG_PATH = $MINION_PRIVATE . '/' . $SERVER_CONFIG_NAME;
my $PROXY_CONFIG_PATH = $MINION_PRIVATE . '/' . $PROXY_CONFIG_NAME;

sub get_nodes 
{
  my ($path) = @_;
  my (%nodes, $node, $fh, $line, $ip, $base_port, $number, $last_ip, $type, $worker, $assigned);

  $type="replica";
  $base_port=30001;

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
      'type' => $type
    };
    $base_port=$base_port+1
  }

  close($fh);

  $nodes{$last_ip}->{'type'} = "client";
  return \%nodes;
}

sub generate_setup
{
    my ($nodes, $target) = @_;
    my ($ifh, $ofh, $line, $ip, $worker, %groups, $tags, $client_ip, $client_port);

  
    foreach $ip (keys(%$nodes)) {
          $line = sprintf("%s:%d", $ip, $nodes->{$ip}->{'port'});
          $tags = $nodes->{$ip}->{'worker'}->region();
          if($nodes->{$ip}->{'type'} eq "client"){
            $client_ip=$ip;
            $client_port=int($nodes->{$ip}->{'port'});
          }
          push(@{$groups{$tags}}, $line);
    }

    if (!open($ofh, '>', $target)) {
        return 0;
    }

    printf($ofh "interface: \"resilientdb\"\n");
    printf($ofh "\n");
    printf($ofh "parameters:\n");
	  printf($ofh "  client_ip: \"$client_ip\"\n");
	  printf($ofh "  client_port: \"$client_port\"\n");
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
    my ($server_config, $client_config, $nodes) = @_;
    my ($ofh, $cfh, $ip, $port, $id, $type);

    if (!open($ofh, '>', $server_config)) {
      return 0;
    }

    if (!open($cfh, '>', $client_config)) {
      return 0;
    }

    $id=1;

    printf($ofh "{\n");
    printf($ofh "\tregion: {\n");

    foreach $ip (keys(%$nodes)) {
        $type = $nodes->{$ip}->{'type'};
        $port = $nodes->{$ip}->{'port'};
        printf("gen config ip $ip, type $type\n");
        if($type eq "client"){
          printf($cfh "$id $ip $port\n");
          next;
        }

        printf($ofh "\t\treplica_info: {\n");
        printf($ofh "\t\t\tid: $id,\n");
        printf($ofh "\t\t\tip: \"$ip\",\n");
        printf($ofh "\t\t\tport: %d\n",$port);
        printf($ofh "\t\t},\n");
        $id = $id + 1
    }
    printf($ofh "\t\tregion_id: 1\n");
    printf($ofh "\t},\n");
    printf($ofh "\tself_region_id: 1,\n");
    printf($ofh "}\n");

    close($ofh);
    close($cfh);

    printf("Write file %s, %s done\n",$server_config, $client_config);
    return 1;
}


sub dispatch_config
{
    my ($server_config, $client_config, $nodes) = @_;
    my ($ip, $worker, $number, $proc, @procs, @stats);

  foreach $ip (keys(%$nodes)) {
      $worker = $nodes->{$ip}->{'worker'};
      $number = $nodes->{$ip}->{'number'};

      if ($number != 1){
        die ("failed to prepare config, only support 1 ip 1 server.");
      }

      $proc = $worker->send([ $server_config, $client_config ], TARGET => $DEPLOY_ROOT);
      if ($proc->wait() != 0) {
        die ("failed to prepare avalanche workers");
      }
    }
}

sub generate_keys
{
    my ($server_config, $client_config, $nodes) = @_;
    my ($ip, $worker, $number, $type, $port, $proc, @procs, @stats);

    foreach $ip (keys(%$nodes)) {
      $worker = $nodes->{$ip}->{'worker'};
      $number = $nodes->{$ip}->{'number'};
      $type = $nodes->{$ip}->{'type'};
      $port = $nodes->{$ip}->{'port'};

      $proc = $RUNNER->run($worker, [ 'deploy-resilientdb-worker','generate', $ip, $port, $type ]);
      if ($proc->wait() != 0) {
        die ("failed to generate keys");
      }
    }
}

sub deploy_resilientdb
{
  my ($simd, $fh, $nodes, $line, $ip, %workers, $worker, $assigned, @workers, $proc);

  if (!(-e $ROLE_PATH)) {
    return 1;
  }

  $nodes = get_nodes($ROLE_PATH);

  if (!build_config($SERVER_CONFIG_PATH, $PROXY_CONFIG_PATH, $nodes)) {
    die ("cannot generate node file '$SERVER_CONFIG_PATH' : $!");
  }

# Prepare deployment for all nodes.
# Like mkdir dictories.
  @workers = map { $_->{'worker'} } values(%$nodes);
  $proc = $RUNNER->run(\@workers, [ 'deploy-resilientdb-worker','prepare' ]);
  if ($proc->wait() != 0) {
    die ("failed to prepare avalanche workers");
  }

# Send configs to all nodes
  if (!dispatch_config($SERVER_CONFIG_PATH, $PROXY_CONFIG_PATH, $nodes)) {
    die ("cannot dispatch node file '$SERVER_CONFIG_PATH' : $!");
  }

# Generate pri-pub keys
  if (!generate_keys($SERVER_CONFIG_PATH, $PROXY_CONFIG_PATH, $nodes)) {
    die ("cannot dispatch node file '$SERVER_CONFIG_PATH' : $!");
  }

# Generate setup.yaml for primary
  if (!generate_setup($nodes, $DIEM_PATH. '/setup.yaml')){
    die ("cannot generate setup file '$DIEM_PATH' : $!");
  }
  return 1;
}


deploy_resilientdb();
__END__
