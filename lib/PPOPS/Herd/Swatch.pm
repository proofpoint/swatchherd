#!perl
# /* Copyright 2013 Proofpoint, Inc. All rights reserved.
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# */


package PPOPS::Herd::Swatch;
use strict;
use warnings;
use File::Spec::Functions;
use File::Basename;
use Digest::SHA1 qw(sha1);
use PPOPS::Herd;
use base qw(PPOPS::Herd);

=head1 NAME

PPOPS::Herd::Swatch - Manage herd of swatches

=head1 SYNOPSIS

   use PPOPS::Herd::Swatch

   my $herd = PPOPS::Herd::Swatch({ 'swatch-location' => 'swatch',
                                    'pidfile-dir' => '/var/run',
                                    'logfile-root' => '/',
                                    'optimize-substring-threshold' => 20,
                                    'ignore-config-dir' => '(CVS|\.svn)' });

   my $status = $herd->status();
   print "/var/log/syslog is being swatched\n"
      if $status->{'/var/log/syslog'} eq 'running';

=head1 DESCRIPTION

This subclass of PPOPS::Herd (see L<PPOPS::Herd>) enables management of a
"herd" of swatch instances using PPOPS::Herd. in the case of swatch, the
instances are logfiles to monitor.

=head2 Options

=over 4

=item swatch-location

Location of swatch executable

=item pidfile-dir

Location of pidfiles

=item logfile-root

Root directory where logfiles are located

=item optimize-substring-threshold

When the following conditions are satisfied, PPOPS::Herd::Swatch generates
a swatch command line that causes swatch to read from a pipeline including
grep for prefiltering on a simple substring. The default is 20.

=back

=over 8

=item *

B<optimize-substring-threshold> is non-zero

=item *

There is only one B<waitfor> definition in swatch.conf

=item *

The B<waitfor> definition starts with a simple string with no regular expression metacharacters. The substring terminates with the first non-alphanumeric character.

=item *

The length of that initial substring is greater than the B<optimize-substring-threshold>.

=back

=over 4

=item ingore-config-dir

Regular expression for directories to ignore when examining the tree
under B<config-root>.

=back

=head2 Methods

=over 4

=item init()

Initialize defaults and scan swatch config dir for files.

=cut

sub init {
   my ($self) = @_;

   $self->{'config'}->{'ignore-config-dir'} ||= '(CVS|\.svn)';
   $self->{'config'}->{'swatch-location'} ||= 'swatch';
   $self->{'config'}->{'pidfile-dir'} ||= '/var/run';
   $self->{'config'}->{'optimize-substring-threshold'} = 20
      unless defined($self->{'config'}->{'optimize-string-threshold'});

   my $croot = $self->{'config'}->{'config-root'};
   $self->{'files'} = { };
   $self->scan_dirs($croot, '');
}

sub dbg3 {
   my ($self, @msg) = @_;

   if ($self->{'config'}->{'debug'} and
          $self->{'config'}->{'debug'} > 2) {
      $self->dbg(@msg);
   }
}

sub scan_dirs {
   my ($self, $croot, $dir) = @_;

   $self->dbg3("scan_dirs('$croot', '$dir')");

   my @entries = $self->_ls($croot, $dir);


   for my $entry (@entries) {
      if (-f catfile($croot, $dir, $entry)) {
         $self->dbg3("   $croot $dir has file: $entry");
         # $dir is a file we have to watch
         $self->{'files'}->{$dir} ||= [ ];
         push(@{$self->{'files'}->{$dir}}, $entry);
      } elsif (-d catfile($croot, $dir, $entry)) {
         $self->scan_dirs($croot, catfile($dir, $entry));
      }
   }

   return $self->{'files'};
}

sub _sum {
   my ($self, $text) = @_;

   return sha1($text);
}

sub _ls {
   my ($self, @dirs) = @_;
   my $dir = catfile(@dirs);
   my @entries;

   if (opendir(my $dirh, $dir)) {
      @entries =
         grep { $_ ne 'swatch.conf' }
            grep { $_ !~ /$self->{'config'}->{'ignore-config-dir'}/ }
               grep { $_ ne '.' and $_ ne '..' }
                  readdir($dirh);
      closedir($dirh);
   }

   return @entries;
}

=item scan()
=item scan(@instances)

Scan named instances (logfiles) using the C<--examine> option of swatch.

=cut

# Special swatchherd method for doing one-time scan of configured logfiles
sub scan {
   my ($self, @instances) = @_;
   my $status = { };

   $self->update_config();

   @instances = $self->instances() unless @instances;
   $self->notice("scanning logfiles: " . join(', ', @instances));

   for my $instance (@instances) {
      $status->{$instance} = $self->scan_one($instance);
   }

   return $status;
}

=item scan_one($instance)

Scan (C<swatch --examine>) one logfile.

=cut

sub scan_one {
   my ($self, $instance) = @_;

   my @cmd = $self->scancmdline($instance);
   return $self->run($instance, @cmd);
}

=item update_config()
=item update_config(@instances)

Update the swatch configuration in all of the directories under the
swatch config root (the B<config-root> option). Regenerates the
C<swatch.conf> file in the appropriate directory if the configuration
has changed. Returns a list of instances whose configuration has
changed.

=cut

sub update_config {
   my ($self, @logfiles) = @_;
   my %changed;

   $self->{'files'} = { };
   $self->scan_dirs($self->{'config'}->{'config-root'}, '');
   @logfiles = $self->logfiles unless @logfiles;

   $self->dbg("updating config: " . join(', ', @logfiles));

   for my $logfile (@logfiles) {
      $self->dbg("Generating configuration for $logfile");
      my $confdir = $self->confdir($logfile);
      my $conffile = $self->conffile($logfile);
      my @files = map { catfile($confdir, $_) }
         @{$self->{'files'}->{$logfile}};
      my $oldcontent = '';
      my $oldsum = '';
      if (-f $conffile) {
         $oldcontent = $self->slurp($conffile);
         $oldsum = $self->_sum($oldcontent);
      }
      # TODO: $newcontent processed in some way?
      my $newcontent = $self->slurp(@files);
      my $newsum = $self->_sum($newcontent);
      if ($newsum eq $oldsum) {
         $self->dbg("Config file $conffile has not changed");
      } else {
         $self->dbg("Updating $conffile");
         unless ($self->{'config'}->{'dry-run'}) {
            my $tf = $conffile . ',' . $$;
            if (open(my $confh, '>', $tf)) {
               print $confh $newcontent;
               close($confh);
               rename($tf, $conffile);
               $changed{$logfile} = 1;
            } else {
               $self->wrn("Can't open $conffile for $logfile - $!");
            }
         }
      }
   }

   return keys %changed;
}

=item cmdline($instance)

Return the command line to invoke swatch in daemon mode for the specified
instance (logfile).

=cut

sub cmdline {
   my ($self, $logfile) = @_;

   my $pidfile = $self->pidfile($logfile);
   my $conffile = $self->conffile($logfile);
   my $tailfile = catfile($self->{'config'}->{'logfile-root'},
                          $logfile);

   $self->dbg3("cmdline($logfile)");

   my $filearg = "--tail-file=$tailfile";

   if ($self->{'config'}->{'optimize-substring-threshold'}) {
      $self->dbg3("considering possible optimization of string in $conffile");
      my $optimal_str = $self->optimal_string($conffile);
      $self->dbg3("   optimal string is " . $self->ddump($optimal_str));
      if (defined($optimal_str) and
             length($optimal_str) >
                $self->{'config'}->{'optimize-substring-threshold'}) {
         $filearg =
            "--read-pipe='tail -F -n 0 \"$tailfile\" | grep \"$optimal_str\"'";
      }
   }

   my @cmd = ($self->{'config'}->{'swatch-location'},
              "--daemon",
              "--config-file=$conffile",
              "--pid-file=$pidfile",
              $filearg);
   push(@cmd, '--debug=3') if
      $self->{'config'}->{'debug'} &&
         $self->{'config'}->{'debug'} > 2;

   return @cmd;
}

sub optimal_string {
   my ($self, $conffile) = @_;
   my @watchfor;

   $self->dbg3("optimal_string('$conffile')");

   my $lineno = 0;
   if (open(my $cfh, '<', $conffile)) {
      while (defined(my $line = <$cfh>)) {
         $lineno++;
         if ($line =~ m{^\s*watchfor( +| *= *)/([A-Za-z0-9\-\_\s]+)(.*)/}) {
            $self->dbg3("found watchfor on line $lineno: $2");
            push(@watchfor, $2);
         }
      }
   }

   if (scalar(@watchfor) == 1) {
      return $watchfor[0];
   } else {
      return undef;
   }
}


=item scancmdline($instance)

Return the command line to invoke swatch in examine mode for the specified
instance (logfile).

=cut

sub scancmdline {
   my ($self, $logfile) = @_;

   my $conffile = $self->conffile($logfile);
   my $tailfile = catfile($self->{'config'}->{'logfile-root'},
                          $logfile);

   my @cmd = ($self->{'config'}->{'swatch-location'},
              "--config-file=$conffile",
              "--examine=$tailfile");
   push(@cmd, '--debug=3') if
      $self->{'config'}->{'debug'} &&
         $self->{'config'}->{'debug'} > 2;

   return @cmd;
}

sub conffile {
   my ($self, $logfile) = @_;

   return catfile($self->confdir($logfile), 'swatch.conf');
}

sub confdir {
   my ($self, $logfile) = @_;

   return catfile($self->{'config'}->{'config-root'},
                  $logfile);
}

=item config_age($instance)

Return the age of the configuration of the name instance (the age of the
config file).

=cut

sub config_age {
   my ($self, $logfile) = @_;

   return (stat($self->conffile($logfile)))[9];
}

=item pidfile($instance)

Return the name of the pidfile for the swatch instance.

=cut

sub pidfile {
   my ($self, $logfile) = @_;

   my $pidfile = $logfile;
   $pidfile =~ s/[^a-zA-Z0-9]+/_/g;
   $pidfile = catfile($self->{'config'}->{'pidfile-dir'},
                      'swatchherd' . $pidfile . '.pid');

   return $pidfile;
}

=item instances()

Return the list of instances configured, based on files existing in a tree
of directories under the B<config-root>.

=cut

sub instances {
   my ($self) = @_;

   return keys %{$self->{'files'}};
}

=item huppable()

Returns false; C<swatch --daemon> cannot be hupped.

=cut

sub huppable {
   my ($self, $instance) = @_;

   return 0;
}

sub logfiles {
   my ($self) = @_;

   return keys %{$self->{'files'}};
}

sub slurp {
   my ($self, @files) = @_;
   my $content;

   for my $file (@files) {
      if (open(my $fh, '<', $file)) {
         $content .= do { local $/; <$fh> };
         close($fh);
      } else {
         $self->wrn("Couldn't read $file - $!");
         return undef;
      }
   }

   return $content;
}

=item to_stop()

Return a list of swatch instances no longer being herded; that should be
stopped.

=cut

sub to_stop {
   my ($self) = @_;

   my $valid_pidfile = { };

   $self->dbg("to_stop() called");

   for my $instance ($self->instances()) {
      $valid_pidfile->{basename($self->pidfile($instance))} = 1;
   }
   $self->dbg("Valid pidfiles: " . join(', ', keys %$valid_pidfile));

   my @pidfiles = grep { /^swatchherd/ }
      $self->_ls($self->{'config'}->{'pidfile-dir'});

   $self->dbg("All pidfiles: " . join(', ', @pidfiles));

   my @pidfiles_to_stop;
   for my $pidfile (@pidfiles) {
      if (exists($valid_pidfile->{$pidfile})) {
         $self->dbg("Pidfile $pidfile is valid");
      } else {
         $self->dbg("Pidfile $pidfile is invalid");
         push(@pidfiles_to_stop, $pidfile);
      }
   }

   $self->dbg("Invalid pidfiles: " . join(', ', keys %$valid_pidfile));

   my @to_stop =
      map { $self->pidfile2instance($_) } @pidfiles_to_stop;

   $self->dbg("Instances to stop: " . join(', ', @to_stop));

   return @to_stop;
}

sub pidfile2instance {
   my ($self, $pidfile) = @_;

   $pidfile = basename($pidfile);
   $pidfile =~ s/^swatchherd//;
   $pidfile =~ s/\.pid$//;
   $pidfile =~ s|_|/|g;

   return $pidfile;
}

=back

=head1 AUTHOR

Jeremy Brinkley, E<lt>jbrinkley@proofpoint.comE<gt>

=cut


1;
