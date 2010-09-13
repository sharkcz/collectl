# copyright, 2003-2007 Hewlett-Packard Development Company, LP
#
# collectl may be copied only under the terms of either the Artistic License
# or the GNU General Public License, which may be found in the source kit

# these are only init'd when in 'record' mode, one of the reasons being that
# many of these variables may be different on the system on which the data
# is being played back on
sub initRecord
{
  print "initRecord()\n"    if $debug & 1;
  initDay();

  # we only write the sexpr header file once. 
  $sexprHeaderWritten=0;

  # In some case, we need to know if we're root.
  $rootFlag=`whoami`;
  $rootFlag=($rootFlag=~/root/) ? 1 : 0;

  # be sure to remove domain portion if present.  also note we keep the hostname in
  # two formats, one in it's unaltered form (at least needed by lustre directory 
  # parsing) as well as all lc because it displays nicer.
  $Host=`hostname`;
  chomp $Host;
  $Host=(split(/\./, $Host))[0];
  $HostLC=lc($Host);

  # For -s p calculations, we need the HZ of the system
  # Note the hack for perl 5.6 which doesn't support PAGESIZE
  $HZ=POSIX::sysconf(&POSIX::_SC_CLK_TCK);
  if ($PerlVers!~/5\.6/)
  {
    $PageSize=POSIX::sysconf(_SC_PAGESIZE);
  }
  else
  {
    $PageSize=($SrcArch=~/ia64/) ? 16384 : 4096;
  }

  # If we have process IO everyone must.  This was added in 2.6.23,
  # but then only if someone builds the kernel with it enabled, though
  # that, will probably change with future kernels.
  $processIOFlag=(-e '/proc/self/io')  ? 1 : 0;
  $slabinfoFlag= (-e '/proc/slabinfo') ? 1 : 0;
  $slubinfoFlag= (-e '/sys/slab')      ? 1 : 0;

  # Get number of cpus, which are used in header of 'raw' file
  $NumCpus=`$Grep cpu /proc/stat | wc -l`;
  $NumCpus=~/(\d+)/;
  $NumCpus=$1-1;
  $temp=`$Grep vendor_id /proc/cpuinfo`;
  $CpuVendor=($temp=~/: (.*)/) ? $1 : '???';
  $temp=`$Grep siblings /proc/cpuinfo`;
  $CpuSiblings=($temp=~/: (\d+)/) ? $1 : 1;  # if not there assume 1
  $temp=`$Grep "cpu cores" /proc/cpuinfo`;
  $CpuCores=($temp=~/: (\d+)/) ? $1 : 1;     # if not there assume 1
  $temp=`$Grep "cpu MHz" /proc/cpuinfo`;
  $CpuMHz=($temp=~/: (.*)/) ? $1 : '???';
  $Hyper=($CpuSiblings/$CpuCores==2) ? "[HYPER]" : "";

  $Memory=`$Grep MemTotal /proc/meminfo`;
  $Memory=(split(/\s+/, $Memory, 2))[1];
  chomp $Memory;
  $Swap=`$Grep SwapTotal /proc/meminfo`;
  $Swap=(split(/\s+/, $Swap, 2))[1];
  chomp $Swap;

  #    D i s k    C h e c k s

  # Location of data is kernel specific.  Note we're also including device
  # mapper info when available
  $procfile=($kernel2_4) ? '/proc/partitions' : '/proc/diskstats';
  $NumDisks=0;
  $DiskNames='';
  $diskFilter="cciss\/c\\d+d\\d+ |hd[ab] |sd[a-z]+ |dm-\\d+";
  @temp=`cat $procfile`;
  foreach $line (@temp)
  {
    next    if $line!~/$diskFilter/;

    # if we have more than 5 columns (which should only happen with 2.4 kernels),
    # we also have performance data here so make a note of it for later.
    @fields=split(/\s+/, $line);
    $partDataFlag=1    if $kernel2_4 && scalar(@fields)>5;

    $diskName=$kernel2_4 ? $fields[4] : $fields[3];
    $dskName[$NumDisks++]=$diskName;
    $DiskNames.="$diskName ";
  }
  $DiskNames=~s/ $//;
  $DiskNames=~s/cciss\///g;

  if ($subsys=~/i/)
  {
    $dentryFlag= (-e '/proc/sys/fs/dentry-state') ? 1 : 0;
    $inodeFlag=  (-e '/proc/sys/fs/inode-state')  ? 1 : 0;
    $filenrFlag= (-e '/proc/sys/fs/file-nr')      ? 1 : 0;
    $supernrFlag=(-e '/proc/sys/fs/super-nr')     ? 1 : 0;
    $dquotnrFlag=(-e '/proc/sys/fs/dquot-nr')     ? 1 : 0;
    if ($debug & 1)
    {
      print "/proc/sys/fs/dentry-state missing\n"    if !$dentryFlag;
      print "/proc/sys/fs/dentry-state missing\n"    if !$inodeFlag;
      print "/proc/sys/fs/dentry-state missing\n"    if !$filenrFlag;
      print "/proc/sys/fs/dentry-state missing\n"    if !$supernrFlag;
      print "/proc/sys/fs/dentry-state missing\n"    if !$dquotnrFlag;
    }

    $OFMax=`cat /proc/sys/fs/file-nr`;
    $OFMax=(split(/\s+/, $OFMax))[2];
    chomp $OFMax;
    $SBMax=(-e "/proc/sys/fs/super-max") ? `cat /proc/sys/fs/super-max` : 0;
    chomp $SBMax;
    $DQMax=(-e "/proc/sys/fs/dquot-max") ? `cat /proc/sys/fs/dquot-max` : 0;
    chomp $DQMax;
  }

  #    I n t e r c o n n e c t    C h e c k s

  # Since the build of the IB code only checks is -sx and we want to know about
  # IB speeds for plain on -sn, let's just do this non-conditionally and then
  # only for ofed.  Furthermore I'm going to assume that even if mulitple IB 
  # interfaces they're all the same
  # speed, at least for now...
  $ibSpeed='??';
  if (-e '/sys/class/infiniband')
  {
    $line=`cat /sys/class/infiniband/*/ports/1/rate`;
    if ($line=~/\s*(\d+)\s+(\S)/)
    {
      $ibSpeed=$1;
      $ibSpeed*=1000    if $2 eq 'G';
    }
  }

  # if doing interconnect, the first thing to do is see what interconnect
  # hardware is present via lspci.  Note that from the H/W database, we get
  # the following IDS -Quadrics: 14fc, Myricom: 14c1, Mellanox (IB): 15b3
  # OR 0c06.
  # we also have to make sure in the right position of output of lspci command
  # so need to be a little clever
  $NumXRails=$NumHCAs=0;
  $myrinetFlag=$quadricsFlag=$mellanoxFlag=0;
  if ($subsys=~/x/i)
  {
    my $lspciVer=`$Lspci --version`;
    $lspciVer=~/ (\d+\.\d+)/;
    $lspciVer=$1;
    my $lspciVendorField=($lspciVer<2.2) ? 3 : 2;
    print "lspci -- Version: $lspciVer  Vendor Field: $lspciVendorField\n"
	if $debug & 1;

    $command="$Lspci -n | $Egrep '15b3|0c06|14c1|14fc'";
    print "Command: $command\n"    if $debug & 1;
    @pci=`$command`;
    foreach $temp (@pci)
    {
      # Save the type in case we ever need that level of discrimination.
      ($vendorID, $type)=split(/:/,(split(/\s+/, $temp))[$lspciVendorField]);
      if ($vendorID eq '14c1')
      {
        printf "WARNING: found myrinet card but no collectl support\n";
      }

      if ($vendorID eq '14fc')
      {
	print "Found Quadrics Interconnect\n"    if $debug & 1;
        $quadricsFlag=1;
	elanCheck();
      }

      if ($vendorID=~/15b3|0c06/)
      {
	next    if $type eq '5a46';    # ignore pci bridge
	print "Found Infiniband Interconnect\n"    if $debug & 1;
	$mellanoxFlag=1;
	$HCANames='';
        ibCheck('');

        # get IB version noting most systems are moving to ofed
        if ($PQuery ne '')
	{
 	  my $dirname=dirname($PQuery);
          $IBVersion=(`$dirname/ofed_info|head -n1`=~/OFED-(.*)/) ? $1 : '???';
	}
	elsif ( -e $VoltaireStats)
        {
  	  $IBVersion=(`head -n1 $VoltaireStats`=~/ibstat\s+(.*)/) ? $1 : '???';
        }
      }
    }

    if ($myrinetFlag+$quadricsFlag+$mellanoxFlag==0)
    {
      logmsg("W", "-sx disabled because no interconnect hardware/drivers found");
      $xFlag=$XFlag=0;
      $subsys=~s/x//ig;
    }

    # User had ability to turn off in case they don't want destructive monitoring
    if ($mellanoxFlag)
    {
      $message='';
      $message="Open Fabric IB Stats disabled in collectl.conf"    if  -e $SysIB && $PQuery eq '';
      $message="Voltaire IB Stats disabled in collectl.conf"       if !-e $SysIB && $PCounter eq '';
      if ($message ne '')
      {
        logmsg("W", $message);
        $xFlag=$XFlag=0;
        $subsys=~s/x//ig;
      }
    }

    # One last check and this is a doozie!  Because we read IB counters by doing
    # a read/clear everytime, multiple copies of collectl will step on each other.
    # Therefore we can only allow one instance to actually monitor the IB and the
    # first one wins, unless we're trying to start a daemon in which case we let 
    # step on the other [hopefully temporary] instance.
    if ($mellanoxFlag)
    {
      $command="$Ps axo pid,cmd | $Grep collectl | $Grep -v grep";
      foreach my $line (`$command`)
      {
        $line=~s/^\s+//;    # show pids have leading white space
        my ($pid, $procCmd)=split(/ /, $line, 2);
        next    if $pid==$$;

        # There are just too many ways one can specify the subsystems whether it's
        # overriding the DaemonCommands or SubsysCore in collectl.conf, using an
        # alternate collectl.conf or specifying --subsys instead of -s  and I'm 
        # just not going to go there [for now] as it's complicated enough.

        # If a daemon, subsys comes out of collectl.conf; otherwise it's already
        # loaded into '$procCmd'
        my $tempDaemonFlag=($procCmd=~/-D/) ? 1 : 0;
        $procCmd=`$Grep 'DaemonCommands =' /etc/collectl.conf`    if $tempDaemonFlag;

        # if +/-, it's the immediate character following the -s (after we get rid
        # of leading white space and any subsystems follow until the next switch
        chomp $procCmd;
        $procCmd.='-';           # make =~// below work in case -s at very end
        $procCmd=~/-s(.+?)-/;
        $procSubsys=(defined($1)) ? $1 : '';
        #print "PID: $pid  ProcCommand: $procCmd  Subsys: $procSubsys\n";

        # The default subsys is different for daemon and interactive use
        # if no -s, we use default and if there, assume we're overriding
        my $tempSubsysDef=($tempDaemonFlag)  ? $SubsysDefDaemon : $SubsysDefInt;
        my $tempSubsys=($procSubsys eq '') ? $tempSubsysDef : $procSubsys;

        # But if + or -, we either combine or substract instead
        $tempSubsys=$tempSubsysDef.$procSubsys    if $procSubsys=~/\+/;
        if ($procSubsys=~/-/)
        {
          $tempSubsys=$tempSubsysDef;
          $tempSubsys=~s/[$procSubsys]//g;
        }
	#print "TempSubsys: $tempSubsys\n";
        
	# At this point if there IS an instance of collectl running with -sx,
        # we need to disable it here, unless we're a daemon in which case we
        # just log a warning.
        if ($tempSubsys=~/x/i)
        {
	  if (!$daemonFlag)
          {
            logmsg("W", "-sx disabled because another instance already monitoring Infiniband");
            $xFlag=$XFlag=0;
            $subsys=~s/x//ig;
          }
          else
          {
            logmsg("W", "another instance is monitoring IB and the stats will be in error until it is stopped");
          }
          last;
        }
      }
    }
  }

  #    E n v i r o n m e n t a l    C h e c k s

  if ($subsys=~/E/)
  {
    error("Environmental data not being collected")
	if !-e "/proc/cpqfan" || !-e "/proc/cpqpwr" || !-e "/proc/cpqtemp";

    # Get maximum numbers for fans, power and temp.
    $NumFans= (split(/\s+/, `tail -n 1 /proc/cpqfan`))[1];
    $NumPwrs= (split(/\s+/, `tail -n 1 /proc/cpqpwr`))[1];
    $NumTemps=(split(/\s+/, `tail -n 1 /proc/cpqtemp`))[1];
  }

  # find all the networks and when possible include thier speeds
  undef @temp;
  $NumNets=0;
  @temp=`$Grep -v -E "Inter|face" /proc/net/dev`;
  $NetNames='';
  $NetWidth=5; # Minimum size
  $null=($debug & 1) ? '' : '2>/dev/null';
  my $interval1=(split(/:/, $interval))[0];
  foreach $temp (@temp)
  {
    $temp=~/^\s*(.*):/;    # most names have leading whitespace
    $netName=$1;
    $NetWidth=length($netName)    if length($netName)>$NetWidth;
    $speed=($netName=~/^ib/) ? $ibSpeed : '';
    if ($rootFlag && $netName=~/eth/ && $Ethtool ne '')
    {
      $command="$Ethtool $netName $null | $Grep Speed";
      print "Command: $command\n"    if $debug & 1;
      $speed=`$command`;
      $speed=($speed=~/Speed:\s+(\d+)(\S)/) ? "$1" : '??';
      $speed*=1000    if $speed ne '??' && $2 eq 'G';
    }
    $NetNames.="$netName:$speed ";

    # Since speeds are in Mb we really need to multiple by 125 to conver to KB
    $NetMaxTraffic[$NumNets]=($speed ne '' && $speed ne '??') ?
		2*$interval1*$speed*125 : 2*$interval1*$DefNetSpeed*125;
    $NumNets++;
  }
  $NetNames=~s/ $//;
  $NetWidth++;             # make room for trailing colon

  #    S C S I    C h e c k s

  # not entirely sure what to do with SCSI info, but if feels like a good
  # thing to have.  also, if no scsi present deal accordingly
  undef @temp;
  $ScsiInfo='';
  if (-e "/proc/scsi/scsi")
  {
    @temp=`$Grep -E "Host|Type" /proc/scsi/scsi`;
    foreach $temp (@temp)
    {
      if ($temp=~/^Host: scsi(\d+) Channel: (\d+) Id: (\d+) Lun: (\d+)/)
      {
        $scsiHost=$1;
        $channel=$2;
        $id=$3;
        $lun=$4;
      }
      if ($temp=~/Type:\s+(\S+)/)
      {
        $scsiType=$1;
        $type="??";
        $type="SC"    if $scsiType=~/scanner/i;
        $type="DA"    if $scsiType=~/Direct-Access/i;
        $type="SA"    if $scsiType=~/Sequential-Access/i;
        $type="CD"    if $scsiType=~/CD-ROM/i;
        $type="PR"    if $scsiType=~/Processor/i;

        $ScsiInfo.="$type:$scsiHost:$channel:$id:$lun ";
      }
    }
    $ScsiInfo=~s/ $//;
  }

  #    L u s t r e    C h e c k s

  $CltFlag=$MdsFlag=$OstFlag=0;
  $NumLustreFS=$numBrwBuckets=0;
  if ($subsys=~/l/i)
  {
     if (`ls /lib/modules/*/kernel/net/lustre 2>/dev/null|wc -l`==0)     
    {
      logmsg("W", "-sl data collection disabled because this system ".
	          "does not have lustre modules installed");
      $lFlag=$LFlag=$LLFlag=0;
      $subsys=~s/l//ig;
    }
    else
    {
      $OstWidth=$FSWidth=0;
      $NumMds=$NumOst=0;
      $MdsNames=$OstNames=$lustreCltInfo='';
      $inactiveOstFlag=0;
      lustreCheckClt();
      lustreCheckMds();
      lustreCheckOst();
      print "Lustre -- CltFlag: $CltFlag  NumMds: $NumMds  NumOst: $NumOst\n"
	  if $debug & 1;

      if ($CltFlag+$NumMds+$NumOst==0 && $lustreSvcs eq '')
      {
        logmsg("W", "-sl data collection disabled because no lustre services running ".
	          "and I don't know its type.  You will need to use -L to force type.");
        $lFlag=$LFlag=$LLFlag=0;
        $subsys=~s/l//ig;
      }

      # Get Luster and SFS Versions...
      $temp=`$Lctl lustre_build_version 2>/dev/null`;
      $temp=~/version: (.+?)-/m;
      $cfsVersion=$1;
      $sfsVersion='';
      if (-e '/etc/sfs-release')
      {
        $temp=cat('/etc/sfs-release');
	$temp=~/(\d.*)/;
	$sfsVersion=$1;
      }
      elsif (-e "/usr/sbin/sfsmount")
      {
        # XC and client enabler
        $llite=`$Rpm -qa | $Grep lustre-client`;
        $llite=~/lustre-client-(.*)/;
        $sfsVersion=$1;
      }

      # Global to count how many buckets there are for brw_stats
      @brwBuckets=(1,2,4,8,16,32,64,128,256);

      push @brwBuckets, (512,1024)    if $sfsVersion ge '2.2';
      $numBrwBuckets=scalar(@brwBuckets);

      # if we're doing lustre DISK stats, figure out what kinds of disks
      # and then build up a list of them for collection to use.  To keep switch
      # error processing clean, only try to open the file if an MDS or OSS.
      # Since services may not be up, we also need to look at '$lustreSvcs',
      # though ultimately we'll only set the disk types and the maximum buckets
      if ($subsys=~/l/i && $subOpts=~/D/ && ($MdsFlag || $OstFlag || $lustreSvcs=~/[mo]/))
      {
        # The first step is to build up a hash of the sizes of all the
        # existing partitions.  Since we're only doing this once, a 'cat's
        # overhead should be minimal
        @partitions=`cat /proc/partitions`;
        foreach $part (@partitions)
        {
          # ignore blank lines and header
          next    if $part=~/^\s*$|^major/;

          # now for the magic.  Get the partition size and name, but ignore
          # cciss devices on controller 0 OR any devices with partitions
          # noting cciss device partitions end in 'p-digit' and sd partitions
          # always end in a digit.
	  ($size, $name)=(split(/\s+/, $part))[3,4];
  	  $name=~s/cciss\///;
	  next    if $name=~/^c0|^c.*p\d$|^sd.*\d$/; 
          $partitionSize{$name}=$size;
        }

        # Determine which directory to look in based on whether or not there
        # is an EVA present.  If so, we look at 'sd' stats; otherwize 'cciss'
        $LusDiskNames='';
        $LusDiskDir=(-e '/proc/scsi/sd_iostats') ? 
	  '/proc/scsi/sd_iostats' : '/proc/driver/cciss/cciss_iostats';

        # Now find all the stat files, noting that in the case of cciss, we
        # always skip c0 disks since they're local ones...  Also note that
        # if we're doing a showHeader with -Lm or -Lo on a client, the file
        # isn't there AND we don't want to report an error either.
        $openFlag=(opendir(DIR, $LusDiskDir)) ? 1 : 0;
        logmsg('F', "Disk stats requested but couldn't open '$LusDiskDir'")
	    if !$openFlag && !$showHeaderFlag;
        while ($diskname=readdir(DIR))
        {
	  next    if $diskname=~/^\.|^c0/;

  	  # if this has a partition within the range of a service lun,
          # ignore it.
          if ($partitionSize{$diskname}/(1024*1024)<$LustreSvcLunMax)
          {
	    print "Ignoring $diskname because its size of ".
	        "$partitionSize{$diskname} is less than ${LustreSvcLunMax}GB\n"
		    if $debug & 1;
  	    next;
          }
          push @LusDiskNames, $diskname;
          $LusDiskNames.="$diskname ";
        }
        $LusDiskNames=~s/ $//;
        $NumLusDisks=scalar(@LusDiskNames);
        $LusMaxIndex=($LusDiskNames=~/sd/) ? 16 : 24;
      }
    }
  }

  #    S L A B    C h e c k s

  # We now have 2 types of slabs to deal with, either in /proc/slabinfo
  # or in /sys/slab...
  if (!$slubinfoFlag)
  {
    $SlabGetProc=($slabopts eq '') ? 0 : 14;
    $SlabSkipHeader=($kernel2_4) ? 1 : 2;

    $temp=`head -n 1 /proc/slabinfo`;
    $temp=~/(\d+\.\d+)/;
    $SlabVersion=$1;
    $NumSlabs=`cat /proc/slabinfo | wc -l`*1;
    chomp $NumSlabs;
    $NumSlabs-=$SlabSkipHeader;

    if ($SlabVersion!~/^1\.1|^2/)
    {
      # since 'W' will echo on terminal, we only use when writing to files
      $severity=(defined($opt_s)) ? "E" : "I";
      $severity="W"    if $logToFileFlag;
      logmsg($severity, "unsupported /proc/slabinfo version: $SlabVersion");
      $subsys=~s/y//gi;
      $yFlag=$YFlag=0;
    }
  }
}

# Why is initFormat() so damn big?
# 
# Since logs can be analyzed on a system on which they were not generated
# and to avoid having to read the actual data to determine things like how
# many cpus or disks there are, this info is written into the log file 
# header.  initFormat() then reads this out of the head and initialized the
# corresponding variables.
#
# Counters are always incrementing (until they wrap) and therefore to get the
# value for the current interval one needs decrement it by the sample from
# the previous interval.  Therefore, theere are 3 different types of 
# variables to deal with:
# - current sample: some 'root', ends in 'Now'
# - last sample:    some 'root', end in 'Last'
# - true value:     'root' only - rootNow-rootLast
#
# To make all this work the very first time through, all 'Last' variables 
# need to be initialized to 0 both to suppress -w initialization warnings AND
# because it's good coding practice.  Furthermore, life is a lot cleaner just
# to initialize everything whether we've selected the corresponding subsystem
# or not.  Furthermore, since it is possible to select a subsystem in plot
# mode for which we never gathered any data, we need to initialize all the 
# printable values to 0s as well.  That's why there is so much crap in 
# initFormat().

sub initFormat
{
  my $playfile=shift;
  my ($day, $mon, $year, $i, $recsys, $host);
  my ($version, $datestamp, $timestamp, $interval);

  $temp=(defined($playfile)) ? $playfile : '';
  print "initFormat($temp)\n"    if $debug & 1;

  # Constants local to formatting
  $OneKB=1024;
  $OneMB=1024*1024;
  $OneGB=1024*1024*1024;
  $TenGB=$OneGB*10;

  # if in normalize mode we report "/sec", otherwise "/int"
  $rate=$options!~/n/ ? "/sec" : "/int";

  if (defined($playfile))
  {
    $header=getHeader($playfile);
    return undef    if $header eq '';

    # save the first two lines of the header for writing into the new header.
    # since the Deamon Options have been renamed in V1.5.3 we need to get a 
    # little trickier to handle both.  Since they are so specific I'm leaving
    # them global.
    $header=~/(Collectl.*)/;
    $recHdr1=$1;
    $recHdr2=(($header=~/(Daemon Options: )(.*)/ || $header=~/(DaemonOpts: )(.*)/) && $2 ne '') ? "$1$2" : "";

    $header=~/Collectl:\s+V(\S+)/;
    $version=$1;
    $hiResFlag=$1    if $header=~/HiRes:\s+(\d+)/;   # only after V1.5.3

    # we want to preserve original subsys from the header, but we
    # also want to override it if user did a -s.  If user specified a
    # +/- we also need to deal with as in collectl.pl, but in this
    # case without the error checking since it already passed through.
    $header=~/SubSys:\s+(\S+)\s+SubOpts:\s+(\S*)\s*Options/;
    $subsys=$recSubsys=$1;
    $subOpts=$2;
    $recHdr1.=" Subsys: $subsys";
    if ($userSubsys ne '')
    {
      if ($userSubsys!~/[+-]/)
      {
	$subsys=$userSubsys;
      }
      else
      {
        $temp=$recSubsys;
        if ($userSubsys=~/-(.*)/)
        {
          $pat=$1;
          $pat=~s/\+.*//;      # if followed by '+' string
          $temp=~s/[$pat]//g;  # remove matches
        }
        if ($userSubsys=~/\+(.*)/)
        {
          $pat=$1;
          $pat=~s/-.*//;       # remove anything after '-' string
          $temp="$temp$pat";   # add matches
        }
        $subsys=$temp;      
      }
    }

    # Now we have to adjust the subopts to match the subsystems being reported
    # on or we're trip error checks in the mainline.
    $subOpts=~s/[BDMR]//g   if $subsys!~/l/i;
    $subOpts=~s/[C23]//g    if $subsys!~/f/i;
    $subOpts.='3'           if $subsys=~/f/i && $subOpts!~/[23]/;   # defaul for -sf

    # I'm not sure the Mds/Ost/Clt names still need to be initialized
    # but it can't hurt.  Clearly the 'lustre' variables do.
    $MdsNames=$OstNames=$lustreClts='';
    $lustreMdss=$lustreOsts=$lustreClts='';

    # We ONLY override the settings for the raw file, never any others.
    # Even though currently only 'rawp' files, we're doing pattern match below
    # with [p] to make easier to add others if we ever need to.
    $playfile=~/(.*-\d{8})-\d{6}\.raw([p]*)/;
    if (defined($playbackSettings{$1}) && $2 eq '')
    {
      # NOTE - when -L not specified for lustre, $lustreSvcs will end up being 
      # set to the combined values of all files for this prefix
      ($subsys, $lustreSvcs, $lustreMdss, $lustreOsts, $lustreClts)=
		split(/\|/, $playbackSettings{$1});
      print "OVERRIDES - Subsys: $subsys  LustreSvc: $lustreSvcs  ".
	    "MDSs: $lustreMdss Osts: $lustreOsts Clts: $lustreClts\n"
			if $debug & 2048;
    }
    print "Playfile: $playfile  Subsys: $subsys  SubOpts: $subOpts\n"
	     if $debug & 1;
    setFlags($subsys);

    # In case not in current file header but defined within set for prefix/date
    $CltFlag=$MdsFlag=$OstFlag=$NumMds=$NumOst=$OstWidth=$FSWidth=0;
    $MdsNames=$lustreMdss    if $lustreMdss ne '';
    $OstNames=$lustreOsts    if $lustreOsts ne '';

    # Maybe some day we can get rid of pre 1.5.0 support?
    $numBrwBuckets=0;
    if ($header=~/Lustre/ && $version ge '1.5.0')
    {
      # Remember, we could have cfs without sfs so need 2 separate pattern tests
      $cfsVersion=$sfsVersion='';
      if ($version ge '2.1')
      {
        $header=~/LustreVersion:\s+(\S+)/;
	$cfsVersion=$1;
	$header=~/SfsVersion:\s+(\S+)/;
	$sfsVersion=$1;
      }

      # In case not already defined (for single or consistent files, these are
      # not specified as overrides), get them from the file header.  Note that
      # when no osts, this will grab the next line it I include \s* after
      # OstNames:, so for now I'm doing it this way and chopping leading space.
      $MdsHdrNames=$OstHdrNames='';
      if ($header=~/MdsNames:\s+(.*)\s*NumOst:\s+\d+\s+OstNames:(.*)$/m)
      {
        $MdsHdrNames=$1;
        $OstHdrNames=$2;
	$OstHdrNames=~s/\s+//;

        $MdsNames=($lustreMdss ne '') ? $lustreMdss : $MdsHdrNames;
        $OstNames=($lustreOsts ne '') ? $lustreOsts : $OstHdrNames;
      }

      if ($MdsNames ne '')
      {
        @MdsMap=remapLustreNames($MdsHdrNames, $MdsNames, 0)    if $MdsHdrNames ne '';
      	foreach $name (split(/ /, $MdsNames))
      	{	
          $NumMds++;
	  $MdsFlag=1;
        }
      }

      if ($OstNames ne '')
      {
        # This build list for interpretting input from 'raw' file if there is any
        @OstMap=remapLustreNames($OstHdrNames, $OstNames, 0)    if $OstHdrNames ne '';

        # This builds data needed for display
        foreach $name (split(/ /, $OstNames))
        {
	  $lustreOstName[$NumOst]=$name;
          $lustreOsts[$NumOst++]=$name;
	  $OstWidth=length($name)    if length($name)>$OstWidth;
	  $OstFlag=1;
        }
      }

      if ($header=~/CltInfo:\s+(.*)$/m)
      {
        $CltHdrNames=$1;
        $lustreCltInfo=($lustreCltInfo ne '') ? $lustreCltInfo : $CltHdrNames;
      }

      undef %fsNames;
      $CltFlag=$NumLustreFS=$NumLustreCltOsts=0;
      $lustreCltInfo=$lustreClts    if $lustreClts ne '';
      if ($lustreCltInfo ne "")
      {
        $CltFlag=1;
        foreach $name (split(/ /, $lustreCltInfo))
        {
          ($fsName, $ostName)=split(/:/, $name);

          $lustreCltFS[$NumLustreFS++]=$fsName    if !defined($fsNames{$fsName});
          $fsNames{$fsName}=1;
          $FSWidth=length($fsName)    if length($fsName)>$FSWidth;

          # if osts defined, we just overwrite anything with did for the non-ost
          if ($ostName ne '')
          {
	    $lustreCltOsts[$NumLustreCltOsts]=$ostName;
            $lustreCltOstFS[$NumLustreCltOsts]=$fsName;
            $OstWidth=length($ostName)    if length($ostName)>$OstWidth;
            $NumLustreCltOsts++;
          }
        }

        @CltFSMap= remapLustreNames($CltHdrNames, $lustreCltInfo, 1)
	    if defined($CltHdrNames);
        @CltOstMap=remapLustreNames($CltHdrNames, $lustreCltInfo, 2)
	    if defined($CltHdrNames);
      }
      print "CLT: $CltFlag  OST: $OstFlag  MDS: $MdsFlag\n"    if $debug & 1;

      # if disk I/O stats specified in header, init appropriate variables
      if ($header=~/LustreDisks.*Names:\s+(.*)/)
      {
        @lusDiskDirs=split(/\s+/, $1);
	$NumLusDisks=scalar(@lusDiskDirs);
        $LusDiskNames=$1;
	@LusDiskNames=split(/\s+/, $LusDiskNames);
      }
    }
    else    # PRE 1.5.0 lustre stuff goes here...
    {
      if ($header=~/NumOsts:\s+(\d+)\s+NumMds:\s+(\d+)/)
      {
        $NumOst=$1;
        $NumMds=$2;
	$OstNames=$MdsNames='';
	for ($i=0; $i<$NumOst; $i++)
	{
	  $OstMap[$i]=$i;
	  $OstNames.="Ost$i ";
	  $lustreOsts[$i]="Ost$i";
	  $OstWidth=length("Ost$i")    if length("ost$i")>$OstWidth;
	  $OstFlag=1;	
	}
	$OstNames=~s/ $//;

	for ($i=0; $i<$NumMds; $i++)
	{
	  $MdsMap[$i]=$i;
	  $MdsNames.="Mds$i ";
	  $MdsFlag=1;	
	}
	$MdsNames=~s/ $//;
      }

      $NumLustreFS=$NumLustreCltOsts=0;
      if ($header=~/FS:\s+(.*)\s+Luns:\s+(.*)\s+LunNames:\s+(.*)$/m)
      {
	$CltFlag=1;
	$tempFS=$1;
        $tempLuns=$2;
        $tempFSNames=$3;

        foreach $fsName (split(/ /, $tempFS))
        {
          $CltFSMap[$NumLustreFS]=$NumLustreFS;
	  $lustreCltFS[$NumLustreFS]=$fsName;
          $FSWidth=length($fsName)    if length($fsName)>$FSWidth;
	  $NumLustreFS++;
        }

	# If defined, user did -sLL need to reset FS info
	# Also note that since these numbers appear in raw data, we can't use a
        # simple index but rather need lun number
	if ($tempLuns ne '')
        {
	  # The lun numbers will be mapped into OSTs
          foreach $lunNum (split(/ /, $tempLuns))
          {
            $CltFSMap[$lunNum]=$NumLustreCltOsts;
            $CltOstMap[$lunNum]=$NumLustreCltOsts;
	    $lustreCltOsts[$NumLustreCltOsts]=$lunNum;
            $OstWidth=length($lunNum)    if length($lunNum)>$FSWidth;
	    $NumLustreCltOsts++;
	  }
	  $NumLustreFS=0;
          foreach $fsName (split(/ /, $tempFSNames))
          {
	    $lustreCltOstFS[$NumLustreFS]=$fsName;
            $FSWidth=length($fsName)    if length($fsName)>$FSWidth;
	    $NumLustreFS++;
          }
        }
      }
    }

    $header=~s/Envron/Environ/;   # to handle typo in pre 1.12 versions

    $header=~/Host:\s+(\S+)/;
    $Host=$1;
    $HostLC=lc($Host);

    # we need this for timezone conversions...
    $header=~/Date:\s+(\d+)-(\d+)/;
    $datestamp=$1;
    $timestamp=$2;
    $timesecs=$timezone='';  # for logs generated with older versions
    if ($header=~/Secs:\s+(\d+)\s+TZ:\s+(.*)/)
    {
      $timesecs=$1;
      $timezone=$2;
    }

    # Allows us to move its location in the header
    $header=~/Interval: (\S+)/;
    $interval=$1;

    # For -s p calculations, we need the HZ of the system
    $header=~/HZ:\s+(\d+)\s+Arch:\s+(\S+)/;
    $HZ=$1;
    $SrcArch=$2;

    # In case pagesize not defined in header (for earlier versions
    # of collectl) pick a default based on architecture;
    $PageSize=($SrcArch=~/ia64/) ? 16384 : 4096;
    $PageSize=$1    if $header=~/PageSize:\s+(\d+)/;

    # when playing back from a file we need to make sure the KERNEL is that of
    # the file and not the one the data was collected on.
    $header=~/OS:\s+(.*)/         if $version lt '1.3.3';
    $header=~/Kernel:\s+(\S+)/    if $version ge '1.3.3';;
    $Kernel=$1;
    setKernelFlags($Kernel);

    $header=~/NumCPUs:\s+(\d+)/;
    $NumCpus=$1;
    $Hyper=($header=~/HYPER/) ? "[HYPER]" : "";

    $flags=($header=~/Flags:\s+(\S+)/) ? $1 : '';
    $processIOFlag=($flags=~/i/) ? 1 : 0;
    $slubinfoFlag= ($flags=~/s/) ? 1 : 0;
    
    $header=~/Memory:\s+(\d+)/;
    $Memory=$1;

    $header=~/NumDisks:\s+(\d+)\s+DiskNames:\s+(.*)/;
    $NumDisks=$1;
    $DiskNames=$2;

    $header=~/NumNets:\s+(\d+)\s+NetNames:\s+(.*)/;
    $NumNets=$1;
    $NetNames=$2;
    $NetWidth=5;
    my $index=0;
    my $interval1=(split(/:/, $interval))[0];
    foreach my $netName (split(/ /, $NetNames))
    {
      my $speed=($netName=~/:(\d+)/) ? $1 : $DefNetSpeed;
      $speed*=1000    if $speed==10 && $version le '2.4.2';    # had missed the 'G'
      $NetMaxTraffic[$index]=2*$interval1*$speed*125;
      $netName=~s/:.*//;
      $NetWidth=length($netName)    if $NetWidth<length($netName);
      $index++;
    }
    $NetWidth++;

    # shouldn't hurt if no slabs defined since we only use during slab reporting
    # but if there ARE slabs and not the slub allocator, we've got the older type
    $header=~/NumSlabs:\s+(\d+)\s+Version:\s+(\S+)/;
    $NumSlabs=$1;
    $SlabVersion=$2;
    $slabinfoFlag=1    if $NumSlabs && !$slubinfoFlag;

    # If using the SLUB allocator, the data has been recorded using the 'root' names for each
    # slab and when we print the data we want the 'first' name which we need to extract from
    # the header.  All other data in $slabdata{} will be populated as the raw data is read in.
    if ($slubinfoFlag)
    {
      my $skipFlag=1;
      foreach my $line (split(/\n/, $header))
      {
	if ($line=~/#SLUB/)
        {
  	  $skipFlag=0;
	  next;
        }
	next    if $skipFlag;
        next    if $line=~/^##/;

	$line=~s/^#//;
	my ($slab, $first)=split(/\s+/, $line);
        $slabfirst{$first}=$slab;
      }
    }

    # Since what is recorded for slabs is identical whether y or Y, we want 
    # to be able to let someone who recorded with -sy play it back with -sY
    # and so the extra diddling with $yFlag and $YFlag.  Eventually we may
    # find other flags to diddle too.
    $yFlag=$YFlag=1    if $userSubsys=~/y/i;

    # This one not always present in header
    $NumXRails=0;
    $XType=$XVersion='';
    if ($header=~/NumXRails:\s+(\d+)\s+XType:\s+(\S*)\s+XVersion:\s+(\S*)/m)
    {
      $NumXRails=$1;
      $XType=$2;
      $XVersion=$3;
    }

    # Nor this
    $NumHCAs=0;
    if ($header=~/NumHCAs:\s+(\d+)\s+PortStates:\s+(\S+)/m)
    {
      $NumHCAs=$1;
      $portStates=$2;
      for ($i=0; $i<$NumHCAs; $i++)
      {
	# The first 2 chars are the states for ports 1 and 2.  The last HCA will
        # only have 2 chars and therefore we don't try to shift.
	$HCAPorts[$i][1]=substr($portStates, 0, 1);
	$HCAPorts[$i][2]=substr($portStates, 1, 1);
	$portStates=substr($portStates, 3)    if length($portStates)>2;
      }
    }

    # In case not defined in header and requested for display.
    $OFMax=$SBMax=$DQMax=0;
    if ($header=~/OF-Max:\s+(\d+)\s+SB-Max:\s+(\d+)\s+DQ-Max:\s+(\d+)/)
    {
      $OFMax=$1;
      $SBMax=$2;
      $DQMax=$3;
    }

    # Scsi info is optional
    $ScsiInfo=($header=~/SCSI:\s+(.*)/) ? $1 : '';

    $NumFans=$NumPwrs=$NumTemps=0;
    if ($header=~/Environ:\s+Fans:\s+(\d+)\s+Power:\s+(\d+)\s+Temp:\s+(\d+)/)
    {
      $NumFans=$1;
      $NumPwrs=$2;
      $NumTemps=$3;
    }

    # Now we can safely load dskNames array
    @dskName=split(/\s+/, $DiskNames);
  }

  # Initialize global arrays with sizes of buckets for lustre brw stats and
  # not to worry if lustre not there.
  @brwBuckets=(1,2,4,8,16,32,64,128,256);
  push @brwBuckets, (512,1024)    if defined($sfsVersion) && $sfsVersion ge '2.2';
  $numBrwBuckets=scalar(@brwBuckets);

  # same thing for lustre disk state though these are a little tricker.
  if ($LusDiskNames=~/sd/)
  {
    @diskBuckets=(.5,1,2,4,8,16,32,64,128,256,512,1024,2048,4096,8192,16384);
  }
  else
  {
    @diskBuckets=(.5,1,2,4,8,16,32,63,64,65,80,96,112,124,128,129,144,252,255,256,257,512,1024,2048);
  }
  $LusMaxIndex=scalar(@diskBuckets);

  # this inits lustre variables in both playback and collection modes.
  initLustre('o',  0, $NumOst);
  initLustre('m',  0, $NumMds);
  initLustre('c',  0, $NumLustreFS);
  initLustre('c2', 0, $NumLustreCltOsts)    if $NumLustreCltOsts ne '-';

  #    I n i t i a l i z e    ' L a s t '    V a r i a b l e s

  $ctxtLast=$intrptLast=$procLast=0;
  $rpcCallsLast=$rpcBadAuthLast=$rpcBadClntLast=0;
  $rpcRetransLast=$rpcCredRefLast=0;
  $nfsPktsLast=$nfsUdpLast=$nfsTcpLast=$nfsTcpConnLast=0;
  $pageinLast=$pageoutLast=$swapinLast=$swapoutLast=0;
  $opsLast=$readLast=$readKBLast=$writeLast=$writeKBLast=0;

  for ($i=0; $i<18; $i++)
  {
    $nfs2ValuesLast[$i]=0;
  }

  for ($i=0; $i<22; $i++)
  {
    $nfsValuesLast[$i]=0;
  }

  for ($i=0; $i<=$NumCpus; $i++)
  {
    $userLast[$i]=$niceLast[$i]=$sysLast[$i]=$idleLast[$i]=0;
    $waitLast[$i]=$irqLast[$i]=$softLast[$i]=$stealLast[$i]=0;
  }

  # ...and disks
  for ($i=0; $i<$NumDisks; $i++)
  {
    $dskOpsLast[$i]=0;
    $dskReadLast[$i]=$dskReadKBLast[$i]=$dskReadMrgLast[$i]=$dskReadTicksLast[$i]=0;
    $dskWriteLast[$i]=$dskWriteKBLast[$i]=$dskWriteMrgLast[$i]=$dskWriteTicksLast[$i]=0;
    $dskInProgLast[$i]=$dskTicksLast[$i]=$dskWeightedLast[$i]=0;

    # 2.6 kernel uses @dskFieldslast
    for ($j=0; $j<11; $j++)
    {
      $dskFieldsLast[$i][$j]=0;
    }
  }

  for ($i=0; $i<$NumNets; $i++)
  {
    $netRxKBLast[$i]=$netRxPktLast[$i]=$netTxKBLast[$i]=$netTxPktLast[$i]=0;
    $netRxErrLast[$i]=$netRxDrpLast[$i]=$netRxFifoLast[$i]=$netRxFraLast[$i]=0;
    $netRxCmpLast[$i]=$netRxMltLast[$i]=$netTxErrLast[$i]=$netTxDrpLast[$i]=0;
    $netTxFifoLast[$i]=$netTxCollLast[$i]=$netTxCarLast[$i]=$netTxCmpLast[$i]=0;
  }

  $NumTcpFields=65;
  for ($i=0; $i<$NumTcpFields; $i++)
  {
    $tcpLast[$i]=0;
  }

  # and interconnect
  for ($i=0; $i<$NumXRails; $i++)
  {
    $elanSendFailLast[$i]=$elanNeterrAtomicLast[$i]=$elanNeterrDmaLast[$i]=0;
    $elanRxLast[$i]=$elanRxMBLast[$i]=$elanTxLast[$i]=$elanTxMBLast[$i]=0;
    $elanPutLast[$i]=$elanPutMBLast[$i]=$elanGetLast[$i]=$elanGetMBLast[$i]=0;
    $elanCompLast[$i]=$elanCompMBLast[$i]=0;
  }

  # IB
  for ($i=0; $i<$NumHCAs; $i++)
  {
    for ($j=0; $j<16; $j++)
    {
      # There are 2 ports on an hca, numbered 1 and 2
      $ibFieldsLast[$i][1][$j]=$ibFieldsLast[$i][2][$j]=0;
    }
  }

  # slabs
  for ($i=0; $i<$NumSlabs; $i++)
  {
    $slabObjActLast[$i]=$slabObjAllLast[$i]=0;
    $slabSlabActLast[$i]=$slabSlabAllLast[$i]=0;
  }

  #    I n i t    ' C o r e '    V a r i a b l e s

  # when we're generating plot data and we're either not collecting
  # everything or we're in playback mode and it's not all in raw file, make
  # sure all the core variables that get printed have been initialized to 0s.
  # for disks, nets and pars the core variables are the totals and so get
  # initialized in the initInterval() routine every cycle
  $i=$NumCpus;
  $userP[$i]=$niceP[$i]=$sysP[$i]=$idleP[$i]=$totlP[$i]=0;
  $irqP[$i]=$softP[$i]=$stealP[$i]=$waitP[$i]=0;

  $unusedDCache=$openFiles=$inodeUsed=$superUsed=$dquotUsed=0;
  $loadAvg1=$loadAvg5=$loadAvg15=$loadRun=$loadQue=$ctxt=$intrpt=$proc=0;
  $dirty=$clean=$target=$laundry=$active=$inactive=0;
  $procsRun=$procsBlock=0;
  $pagein=$pageout=$swapin=$swapout=$swapTotal=$swapUsed=$swapFree=0;
  $memTot=$memUsed=$memFree=$memShared=$memBuf=$memCached=$memSlab=$memMap=$memCommit=0;
  $sockUsed=$sockTcp=$sockOrphan=$sockTw=$sockAlloc=0;
  $sockMem=$sockUdp=$sockRaw=$sockFrag=$sockFragM=0;

  # Lustre stuff - in case no data
  $lustreMdsGetattr=$lustreMdsClose=$lustreMdsReint=$lustreMdsSync=0;

  # Common nfs stats
  $rpcCalls=$rpcBadAuth=$rpcBadClnt=$rpcRetrans=$rpcCredRef=0;
  $nfsPkts=$nfsUdp=$nfsTcp=$nfsTcpConn=0;

  # V2
  $nfs2Null=$nfs2Getattr=$nfs2Setattr=$nfs2Root=$nfs2Lookup=$nfs2Readlink=
  $nfs2Read=$nfs2Wrcache=$nfs2Write=$nfs2Create=$nfs2Remove=$nfs2Rename=
  $nfs2Link=$nfs2Symlink=$nfs2Mkdir=$nfs2Rmdir=$nfs2Readdir=$nfs2Fsstat=0;

  # V3
  $nfsNull=$nfsGetattr=$nfsSetattr=$nfsLookup=$nfsAccess=$nfsReadlink=
  $nfsRead=$nfsWrite=$nfsCreate=$nfsMkdir=$nfsSymlink=$nfsMknod=$nfsRemove=
  $nfsRmdir=$nfsRename=$nfsLink=$nfsReaddir=$nfsReaddirplus=$nfsFsstat= 
  $nfsFsinfo=$nfsPathconf=$nfsCommit=$nfsMeta=0;

  # tcp - just do them all!
  for ($i=0; $i<$NumTcpFields; $i++)
  {
    $tcpValue[$i]=0;
  }

  # finally get ready to process first interval.
  $lastSecs=$intervalCounter=$interval2Counter=$interval3Counter=0;
  initInterval();

  #    I n i t    ' E x t e n d e d '    V a r i a b l e s

  # The current thinking is if someone wants to plot extended variables and
  # they haven't been collected (remember the rule that when you report for
  # plotting, you always produce what's in -s) we better intialize the results
  # variables to all zeros.

  for ($i=0; $i<$NumCpus; $i++)
  {
    $userP[$i]=$niceP[$i]=$sysP[$i]=$idleP[$i]=$totlP[$i]=0;
    $irqP[$i]=$softP[$i]=$stealP[$i]=$waitP[$i]=0;
  }

  # these all need to be initialized in case we use /proc/stats since not all variables
  # supplied by that
  for ($i=0; $i<$NumDisks; $i++)
  {
    $dskOps[$i]=$dskTicks[$i]=0;
    $dskRead[$i]=$dskReadKB[$i]=$dskReadMrg[$i]=0;
    $dskWrite[$i]=$dskWriteKB[$i]=$dskWriteMrg[$i]=0;
    $dskRqst[$i]=$dskQueLen[$i]=$dskWait[$i]=$dskSvcTime[$i]=$dskUtil[$i]=0;
  }

  for ($i=0; $i<$NumNets; $i++)
  {
    $netName[$i]="";
    $netRxPkt[$i]=$netTxPkt[$i]= $netRxKB[$i]=  $netTxKB[$i]=  $netRxErr[$i]=
    $netRxDrp[$i]=$netRxFifo[$i]=$netRxFra[$i]= $netRxCmp[$i]= $netRxMlt[$i]=
    $netTxErr[$i]=$netTxDrp[$i]= $netTxFifo[$i]=$netTxColl[$i]=$netTxCar[$i]=
    $netTxCmp[$i]=$netRxErrs[$i]=$netTxErrs[$i]=0;
  }

  # Don't forget infiniband
  for ($i=0; $i<$NumHCAs; $i++)
  {
    $ibTxKB[$i]=$ibTx[$i]=$ibRxKB[$i]=$ibRx[$i]=$ibErrorsTot[$i]=0;
  }

  # if we ever want to map scsi devices to their host/channel/etc, this does it
  # for partitions
  undef @scsi;
  $scsiIndex=0;
  foreach $device (split(/\s+/, $ScsiInfo))
  {
    $scsi[$scsiIndex++]=(split(/:/, $device, 2))[1]    if $device=~/DA/;
  }

  #    C o n s t a n t    H e a d e r    S t u f f

  # I suppose for performance it would be good to build all headers once, 
  # but for now at least do a few pieces.

  # get mini date/time header string according to $options but also note these
  # don't apply to --top mode
  $miniDateTime="";  # so we don't get 'undef' down below
  $miniDateTime="Time     "                  if $miniTimeFlag;
  $miniDateTime="Date Time      "            if $miniDateFlag && $options=~/d/;
  $miniDateTime="Date    Time      "         if $miniDateFlag && $options=~/D/;
  $miniDateTime.="    "                      if $options=~/m/;
  $miniFiller=' ' x length($miniDateTime)    if !$numTop;

  # sometimes we want to shift things 1 space to the left.
  $miniFiller1=substr($miniFiller, 0, length($miniFiller)-1);

  # If we need two lines, we need to align
  $len=length($miniDateTime);
  $miniBlanks=sprintf("%${len}s", '');

  #    S l a b    S t u f f

  $slabIndexNext=0;
  undef %slabIndex;

  #    P r o c e s s   S t u f f

  $procIndexNext=0;

  #    I n t e r v a l 2    S t u f f

  $interval2Counter=0;

  #    A r c h i t e c t u r e    S t u f f

  $word32=2**32;
  $maxword= ($SrcArch=~/ia64|x86_64/) ? 2**64 : $word32;

  return(($version, $datestamp, $timestamp, $timesecs, $timezone, $interval, $recSubsys))
    if defined($playfile);
}

# when playing back lustre data, the indexes on the detail stats may be shifted 
# relative to collectl logs in which other OSTs existed.  In other words in one
# file one may have "ostY ostZ", in a second "ostX ostZ" and in a third "ostY".
# We need to generate index mappings such that ost1 will always map to 0, ost2
# to 1 and so on.
sub remapLustreNames
{
  my $hdrNames=shift;
  my $allNames=shift;
  my $cltType= shift;
  my ($i, $j, $uuid, @hdrTemp, @allTemp, @maps);

  # the names as contained in the header are always unique, including ':ost' for
  # -sLL.  However, for -sLL reporting, we only want the ost part and hence the
  # special treatment.  Type=1 used to be meaningful before I realized stripping
  # off the ':ost' lead to non-unique names and incorrect remapping.
  if ($cltType==2)
  {
    $hdrNames=~s/\S+:(\S+)/$1/g;
    $allNames=~s/\S+:(\S+)/$1/g;
  }
  print "remapLustrenames() -- Type: $cltType HDR: $hdrNames  ALL: $allNames\nREMAPPED: "
	    if $debug & 2;

  if ($hdrNames ne '')
  {
    @hdrTemp=split(/ /, $hdrNames);
    @allTemp=split(/ /, $allNames);
    for ($i=0; $i<scalar(@hdrTemp); $i++)
    {
      for ($j=0; $j<scalar(@allTemp); $j++)
      {
	if ($hdrTemp[$i] eq $allTemp[$j])
        {
	  $maps[$i]=$j;
	  print "Map[$i]=$j "    if $debug & 2;
	  last;
        }
      }
    }
  }
  print "\n"    if $debug & 2;
  return(@maps);
}

# Technically this could get called from within the lustreCheck() routines
# but I didn't want it to get lost there...
sub initLustre
{
  my $type=shift;
  my $from=shift;
  my $to= shift;
  my ($i, $j);

  printf "initLustre() -- Type: $type  From: $from  Number: %s\n",
	  defined($to) ? $to : ''    if $debug & 2;

  # NOTE - we have to init both the 'Last' and running variables in case they're not
  # set during this interval since we don't want to use old values.
  if ($type eq 'o')
  {
    for ($i=$from; $i<$to; $i++)
    {
      $lustreReadOps[$i]=$lustreReadKBytes[$i]=0;
      $lustreWriteOps[$i]=$lustreWriteKBytes[$i]=0;

      $lustreReadOpsLast[$i]=$lustreReadKBytesLast[$i]=0;
      $lustreWriteOpsLast[$i]=$lustreWriteKBytesLast[$i]=0;
      for ($j=0; $j<$numBrwBuckets; $j++)
      {
        $lustreBufRead[$i][$j]=    $lustreBufWrite[$i][$j]=0;
        $lustreBufReadLast[$i][$j]=$lustreBufWriteLast[$i][$j]=0;
      }
    }
  }
  elsif ($type eq 'c')
  {
    for ($i=$from; $i<$to; $i++)
    {
      $lustreCltDirtyHits[$i]=$lustreCltDirtyMiss[$i]=0;
      $lustreCltRead[$i]=$lustreCltReadKB[$i]=0;
      $lustreCltWrite[$i]=$lustreCltWriteKB[$i]=0;
      $lustreCltOpen[$i]=$lustreCltClose[$i]=$lustreCltSeek[$i]=0;
      $lustreCltFsync[$i]=$lustreCltSetattr[$i]=$lustreCltGetattr[$i]=0;

      $lustreCltRAPending[$i]=$lustreCltRAHits[$i]=$lustreCltRAMisses[$i]=0;
      $lustreCltRANotCon[$i]=$lustreCltRAMisWin[$i]=$lustreCltRALckFail[$i]=0;
      $lustreCltRAReadDisc[$i]=$lustreCltRAZeroLen[$i]=$lustreCltRAZeroWin[$i]=0;
      $lustreCltRA2EofMax[$i]=$lustreCltRAHitMax[$i]=0;

      $lustreCltDirtyHitsLast[$i]=$lustreCltDirtyMissLast[$i]=0;
      $lustreCltReadLast[$i]=$lustreCltReadKBLast[$i]=0;
      $lustreCltWriteLast[$i]=$lustreCltWriteKBLast[$i]=0;
      $lustreCltOpenLast[$i]=$lustreCltCloseLast[$i]=$lustreCltSeekLast[$i]=0;
      $lustreCltFsyncLast[$i]=$lustreCltSetattrLast[$i]=$lustreCltGetattrLast[$i]=0;

      $lustreCltRAHitsLast[$i]=$lustreCltRAMissesLast[$i]=0;
      $lustreCltRANotConLast[$i]=$lustreCltRAMisWinLast[$i]=$lustreCltRALckFailLast[$i]=0;
      $lustreCltRAReadDiscLast[$i]=$lustreCltRAZeroLenLast[$i]=$lustreCltRAZeroWinLast[$i]=0;
      $lustreCltRA2EofLast[$i]=$lustreCltRAHitMaxLast[$i]=0;
    }
  }
  elsif ($type eq 'c2')
  {
    # only used for -sLL OR -OB
    for ($i=$from; $i<$to; $i++)
    {
      $lustreCltLunRead[$i]= $lustreCltLunReadKB[$i]=0;
      $lustreCltLunWrite[$i]=$lustreCltLunWriteKB[$i]=0;

      $lustreCltLunReadLast[$i]= $lustreCltLunReadKBLast[$i]=0;
      $lustreCltLunWriteLast[$i]=$lustreCltLunWriteKBLast[$i]=0;

      for ($j=0; $j<$numBrwBuckets; $j++)
      {
        $lustreCltRpcRead[$i][$j]=    $lustreCltRpcWrite[$i][$j]=0;
        $lustreCltRpcReadLast[$i][$j]=$lustreCltRpcWriteLast[$i][$j]=0;
      }
    }
  }
  elsif ($type eq 'm')
  {
    $lustreMdsGetattr=$lustreMdsClose=0;
    $lustreMdsReint=$lustreMdsSync=0;

    $lustreMdsGetattrLast=$lustreMdsCloseLast=0;
    $lustreMdsReintLast=$lustreMdsSyncLast=0;

    # Use maximum size (cciss disk buckets)
    $lusDiskReadsTot[24]=$lusDiskReadBTot[24]=0;
    $lusDiskWritesTot[24]=$lusDiskWriteKBTot[24]=0;
  }

  if ($subOpts=~/D/)
  {
    for (my $i=0; $i<$NumLusDisks; $i++)
    {
      # cciss disks have up to 24 rows, 25 counting total line!
      for (my $j=0; $j<25; $j++)
      {
        $lusDiskReadsLast[$i][$j]=$lusDiskWritesLast[$i][$j]=0;
        $lusDiskReadBLast[$i][$j]=$lusDiskWriteBLast[$i][$j]=0;
      }
    }
  }
}

# as of now, not much happens here
# the 'inactive' flags tell us whether or not an inactive warning was issued
# today for this associated hardware.
sub initDay
{
  $newDayFlag=1;
  $inactiveOstFlag=0;
  $inactiveMyrinetFlag=0;
  $inactiveElanFlag=0;
  $inactiveIBFlag=0;
}

# these variables must be initialized at the start of each interval because
# they occur for multiple devices and/or on multiple lines in the raw file.
sub initInterval
{
  my $i;

  $userP[$NumCpus]=$niceP[$NumCpus]=$sysP[$NumCpus]=$idleP[$NumCpus]=0;
  $irq[$NumCpus]=$softP[$NumCpus]=$stealP[$NumCpus]=$waitP[$NumCpus]=0;

  $netIndex=0;
  $netRxKBTot=$netRxPktTot=$netTxKBTot=$netTxPktTot=0;
  $netEthRxKBTot=$netEthRxPktTot=$netEthTxKBTot=$netEthTxPktTot=0;
  $netRxErrTot=$netRxDrpTot=$netRxFifoTot=$netRxFraTot=0;
  $netRxCmpTot=$netRxMltTot=$netTxErrTot=$netTxDrpTot=0;
  $netTxFifoTot=$netTxCollTot=$netTxCarTot=$netTxCmpTot=0;
  $netRxErrsTot=$netTxErrsTot=0;

  $dskIndex=0;
  $dskOpsTot=$dskReadTot=$dskWriteTot=$dskReadKBTot=$dskWriteKBTot=0;
  $dskReadMrgTot=$dskReadTicksTot=$dskWriteMrgTot=$dskWriteTicksTot=0;  

  if ($reportOstFlag)
  {
    $lustreReadOpsTot=$lustreReadKBytesTot=0;
    $lustreWriteOpsTot=$lustreWriteKBytesTot=0;
    for ($i=0; $i<$numBrwBuckets; $i++)
    {
      $lustreBufReadTot[$i]=$lustreBufWriteTot[$i]=0;
    }
  }
  $lustreCltDirtyHitsTot=$lustreCltDirtyMissTot=0;
  $lustreCltReadTot=$lustreCltReadKBTot=$lustreCltWriteTot=$lustreCltWriteKBTot=0;
  $lustreCltOpenTot=$lustreCltCloseTot=$lustreCltSeekTot=$lustreCltFsyncTot=0;
  $lustreCltSetattrTot=$lustreCltGetattrTot=0;
  $lustreCltRAPendingTot=$lustreCltRAHitsTot=$lustreCltRAMissesTot=0;
  $lustreCltRANotConTot=$lustreCltRAMisWinTot=$lustreCltRALckFailTot=0;
  $lustreCltRAReadDiscTot=$lustreCltRAZeroLenTot=$lustreCltRAZeroWinTot=0;
  $lustreCltRA2EofTot=$lustreCltRAHitMaxTot=0;
  for ($i=0; $i<$numBrwBuckets; $i++)
  {
    $lustreCltRpcReadTot[$i]=$lustreCltRpcWriteTot[$i]=0;
  }
  for ($i=0; $i<25; $i++)
  {
    $lusDiskReadsTot[$i]=$lusDiskWritesTot[$i]=0;
    $lusDiskReadBTot[$i]=$lusDiskWriteBTot[$i]=0;
  }

  $elanSendFailTot=$elanNeterrAtomicTot=$elanNeterrDmaTot=0;
  $elanRxTot=$elanRxKBTot=$elanTxTot=$elanTxKBTot=$elanErrors=0;
  $elanPutTot=$elanPutKBTot=$elanGetTot=$elanGetKBTot=0;
  $elanCompTot=$elanCompKBTot=0;

  $ibRxTot=$ibRxKBTot=$ibTxTot=$ibTxKBTot=$ibErrorsTotTot=0;

  $slabObjActTotal=$slabObjAllTotal=$slabSlabActTotal=$slabSlabAllTotal=0;
  $slabObjActTotalB=$slabObjAllTotalB=$slabSlabActTotalB=$slabSlabAllTotalB=0;
  $slabNumAct=$slabNumTot=0;
  $slabNumObjTot=$slabObjAvailTot=$slabUsedTot=$slabTotalTot=0;    # These are for slub

  # processes and environmentals don't get reported every interval so we need
  # to set a flag when they do.
  $interval2Print=$interval3Print=0;

  # on older kernels not always set.
  $inactive=0;

  # Lustre is a whole different thing since the state of the system we're
  # monitoring change change with each interval.  Since this applies across
  # all types of output, let's just do it once.
  $reportCltFlag=$reportMdsFlag=$reportOstFlag=0;

  # if no -L, report based on system components
  # I would have thought this could have been done once, but now I'm
  # too scared to change it!
  if ($lustreSvcs eq '')
  {
    $reportCltFlag=1    if $CltFlag;
    $reportMdsFlag=1    if $MdsFlag;
    $reportOstFlag=1    if $OstFlag;
  }
  else
  {
    $reportCltFlag=1    if $lustreSvcs=~/c/;
    $reportMdsFlag=1    if $lustreSvcs=~/m/;
    $reportOstFlag=1    if $lustreSvcs=~/o/;
  }
}

# End of interval processing/printing
sub intervalEnd
{
  my $seconds=shift;

  # Only for debugging and typically used with -d4, we want to see the /proc
  # fields as they're read but NOT process them
  return()    if $debug & 32;

  # we need to know how long the interval was (integer for now, but this is the
  # place to handle finer grained time if we change our mind)
  # note that during development/testing, it's sometimes useful to set the
  # interval to 0 to simulate a day's processing.  however, we can't use 0 in
  # calculations.
  $lastSecs=$seconds    if !$intervalCounter;
  $intSecs= $seconds-$lastSecs;
  $intSecs=1            if $options=~/n/ || !$intSecs;
  $lastSecs=$seconds;

  # for interval2, we need to calculate the length of the interval as well,
  # which is usually longer than the base one.  this is also the perfect
  # time to clean out process stale pids from the %procIndexes hash.  
  # Also note the first time, the interval counter will be 1 and we need 
  # 2 interval's worth of data.
  if ($interval2Print)
  {
    cleanStaleTasks()               if $ZFlag && !$pidOnly;
    $lastInt2Secs=$lastSecs         if !defined($lastInt2Secs);
    $interval2Secs=$seconds-$lastInt2Secs;
    $lastInt2Secs=$seconds;
    $interval2Counter++;
  }

  # the first interval only provides baseline data and so never call print
  intervalPrint($seconds)           if $intervalCounter;

  # need to reinitialize all relevant variables at end of each interval,
  # count interval within this set.
  initInterval();
  $intervalCounter++;

  # No longer the first interval of the day
  $newDayFlag=0;
}

sub dataAnalyze
{
  my $subsys=shift;
  my $line=  shift;
  my $i;

  # Only for debugging and typically used with -d4, we want to see the /proc
  # fields as they're read but NOT process them
  return()    if $debug & 32;

  # if running 'live' & non-flushed buffer or in some cases simply no data
  # as in the case of a diskless system, if no data to analyze, skip it
  chomp $line;
  ($type, $data)=split(/\s+/, $line, 2);
  return    if (!defined($data) || $data eq "");

  # if user requested -sd, we had to force -sc so we can get 'jiffies'
  # NOTE - 2.6 adds in wait, irq and softIrq.  2.6 disk stats also need
  # cpu to get jiffies for micro calculations
  if ($type=~/^cpu/ && $subsys=~/c|d|p/i)
  {
    $type=~/^cpu(\d*)/;   # can't do above because second "~=" kills $1
    $cpuIndex=($1 ne "") ? $1 : $NumCpus;    # only happens in pre 1.7.4
    ($userNow, $niceNow, $sysNow, $idleNow, $waitNow, $irqNow, $softNow, $stealNow)=split(/\s+/, $data);
    $waitNow=$irqNow=$softNow=$stealNow=0    if $kernel2_4 && !defined($waitNow);
    $stealNow=0                              if !defined($stealNow);

    if (!defined($idleNow))
    {
      incomplete("CPU", $lastSecs);
      return;
    }

    # we don't care about saving raw seconds other than in 'last' variable
    # Also note that the total number of jiffies may be needed elsewhere (-s p)
    # "wait" doesn't happen unti 2.5, but might as well get ready now.
    $user= fix($userNow-$userLast[$cpuIndex]);
    $nice= fix($niceNow-$niceLast[$cpuIndex]);
    $sys=  fix($sysNow-$sysLast[$cpuIndex]);
    $idle= fix($idleNow-$idleLast[$cpuIndex]);
    $wait= fix($waitNow-$waitLast[$cpuIndex]);
    $irq=  fix($irqNow-$irqLast[$cpuIndex]);
    $soft= fix($softNow-$softLast[$cpuIndex]);
    $steal=fix($stealNow-$stealLast[$cpuIndex]);
    $total=$user+$nice+$sys+$idle+$irq+$soft+$steal;
    $total=1    if !$total;  # has seen to be 0 when interval=0;

    # For some calculations, like disk performance, we use a more exact measure
    # to work with times that are in jiffies
    $microInterval=$total/$NumCpus    if $cpuIndex==$NumCpus;

    $userP[$cpuIndex]= 100*$user/$total;
    $niceP[$cpuIndex]= 100*$nice/$total;
    $sysP[$cpuIndex]=  100*$sys/$total;
    $idleP[$cpuIndex]= 100*$idle/$total;
    $waitP[$cpuIndex]= 100*$wait/$total;
    $irqP[$cpuIndex]=  100*$irq/$total;
    $softP[$cpuIndex]= 100*$soft/$total;
    $stealP[$cpuIndex]=100*$steal/$total;
    $totlP[$cpuIndex]=$userP[$cpuIndex]+$niceP[$cpuIndex]+
		      $sysP[$cpuIndex]+$irqP[$cpuIndex]+
		      $softP[$cpuIndex]+$stealP[$cpuIndex];

    $userLast[$cpuIndex]= $userNow;
    $niceLast[$cpuIndex]= $niceNow;
    $sysLast[$cpuIndex]=  $sysNow;
    $idleLast[$cpuIndex]= $idleNow;
    $waitLast[$cpuIndex]= $waitNow;
    $irqLast[$cpuIndex]=  $irqNow;
    $softLast[$cpuIndex]= $softNow;
    $stealLast[$cpuIndex]=$stealNow;
  }

  elsif ($type=~/^load/ && $subsys=~/c/)
  {
    ($loadAvg1, $loadAvg5, $loadAvg15, $loadProcs)=split(/\s+/, $data);
    if (!defined($loadProcs))
    {
      incomplete("LOAD", $lastSecs);
      return;
    }

    ($loadRun, $loadQue)=split(/\//, $loadProcs);
    $loadRun--;   # never count ourself!
  }

  elsif ($type=~/OST_(\d+)/)
  {
    chomp $data;
    $index=$1;
    ($lustreType, $lustreOps, $lustreBytes)=(split(/\s+/, $data))[0,1,6];
    $index=$OstMap[$index]    if $playback ne '';   # handles remapping is OSTs change position
    #print "IDX: $index, $lustreType, $lustreOps, $lustreBytes\n";

    $lustreBytes=0    if $lustreOps==0;
    if ($lustreType=~/read/)
    {
      $lustreReadOpsNow=            $lustreOps;
      $lustreReadKBytesNow=         $lustreBytes/$OneKB;

      $lustreReadOps[$index]=       fix($lustreReadOpsNow-$lustreReadOpsLast[$index]);
      $lustreReadKBytes[$index]=    fix($lustreReadKBytesNow-$lustreReadKBytesLast[$index]);
      $lustreReadOpsLast[$index]=   $lustreReadOpsNow;
      $lustreReadKBytesLast[$index]=$lustreReadKBytesNow;
      $lustreReadOpsTot+=           $lustreReadOps[$index];
      $lustreReadKBytesTot+=        $lustreReadKBytes[$index];
    }
    else
    {
      $lustreWriteOpsNow=            $lustreOps;
      $lustreWriteKBytesNow=         $lustreBytes/$OneKB;
      $lustreWriteOps[$index]=       fix($lustreWriteOpsNow-$lustreWriteOpsLast[$index]);
      $lustreWriteKBytes[$index]=    fix($lustreWriteKBytesNow-$lustreWriteKBytesLast[$index]);
      $lustreWriteOpsLast[$index]=   $lustreWriteOpsNow;
      $lustreWriteKBytesLast[$index]=$lustreWriteKBytesNow;
      $lustreWriteOpsTot+=           $lustreWriteOps[$index];
      $lustreWriteKBytesTot+=        $lustreWriteKBytes[$index];
    }
  }

  elsif ($type=~/OST-b_(\d+):(\d+)/)
  {
    chomp $data;
    $index=$1;
    $bufNum=$2;
    ($lustreBufReadNow, $lustreBufWriteNow)=(split(/\s+/, $data))[1,5];
    $index=$OstMap[$index]    if $playback ne '';

    $lustreBufRead[$index][$bufNum]=fix($lustreBufReadNow-$lustreBufReadLast[$index][$bufNum]);
    $lustreBufWrite[$index][$bufNum]=fix($lustreBufWriteNow-$lustreBufWriteLast[$index][$bufNum]);

    $lustreBufReadTot[$bufNum]+=$lustreBufRead[$index][$bufNum];
    $lustreBufWriteTot[$bufNum]+=$lustreBufWrite[$index][$bufNum];

    $lustreBufReadLast[$index][$bufNum]= $lustreBufReadNow;
    $lustreBufWriteLast[$index][$bufNum]=$lustreBufWriteNow;
  }

  elsif ($type=~/MDS/)
  {
    chomp $data;
    ($name, $value)=(split(/\s+/, $data))[0,1];
    # if we ever do mds detail, this goes here!
    #$index=$MdsMap[$index]    if $playback ne '';
	
    if ($name=~/getattr/)
    {
      $lustreMdsGetattr=fix($value-$lustreMdsGetattrLast);
      $lustreMdsGetattrLast=$value;
    }
    elsif ($name=~/close/)
    {
      $lustreMdsClose=fix($value-$lustreMdsCloseLast);
      $lustreMdsCloseLast=$value;
    }
    elsif ($name=~/reint/)
    {
      $lustreMdsReint=fix($value-$lustreMdsReintLast);
      $lustreMdsReintLast=$value;
    }
    elsif ($name=~/sync/)
    {
      $lustreMdsSync=fix($value-$lustreMdsSyncLast);
      $lustreMdsSyncLast=$value;
    }
  }

  elsif ($type=~/LLITE:(\d+)/)
  {
    $fs=$1;
    chomp $data;
    ($name, $ops, $value)=(split(/\s+/, $data))[0,1,6];
    $fs=$CltFSMap[$fs]    if $playback ne '';

    if ($name=~/dirty_pages_hits/)
    {
      $lustreCltDirtyHits[$fs]=fix($ops-$lustreCltDirtyHitsLast[$fs]);
      $lustreCltDirtyHitsLast[$fs]=$ops;
      $lustreCltDirtyHitsTot+=$lustreCltDirtyHits[$fs];
    }
    elsif ($name=~/dirty_pages_misses/)
    {
      $lustreCltDirtyMiss[$fs]=fix($ops-$lustreCltDirtyMissLast[$fs]);
      $lustreCltDirtyMissLast[$fs]=$ops;
      $lustreCltDirtyMissTot+=$lustreCltDirtyMiss[$fs];
    }
    elsif ($name=~/read/)
    {

      # if brand new fs and no I/0, this field isn't defined.
      $value=0    if !defined($value);
      $lustreCltRead[$fs]=fix($ops-$lustreCltReadLast[$fs]);
      $lustreCltReadLast[$fs]=$ops;
      $lustreCltReadTot+=$lustreCltRead[$fs];
      $lustreCltReadKB[$fs]=fix(($value-$lustreCltReadKBLast[$fs])/$OneKB);
      $lustreCltReadKBLast[$fs]=$value;
      $lustreCltReadKBTot+=$lustreCltReadKB[$fs];
    }
    elsif ($name=~/write/)
    {
      $value=0    if !defined($value);    # same as 'read'
      $lustreCltWrite[$fs]=fix($ops-$lustreCltWriteLast[$fs]);
      $lustreCltWriteLast[$fs]=$ops;
      $lustreCltWriteTot+=$lustreCltWrite[$fs];
      $lustreCltWriteKB[$fs]=fix(($value-$lustreCltWriteKBLast[$fs])/$OneKB);
      $lustreCltWriteKBLast[$fs]=$value;
      $lustreCltWriteKBTot+=$lustreCltWriteKB[$fs];
    }
    elsif ($name=~/open/)
    {
      $lustreCltOpen[$fs]=fix($ops-$lustreCltOpenLast[$fs]);
      $lustreCltOpenLast[$fs]=$ops;
      $lustreCltOpenTot+=$lustreCltOpen[$fs];
    }
    elsif ($name=~/close/)
    {
      $lustreCltClose[$fs]=fix($ops-$lustreCltCloseLast[$fs]);
      $lustreCltCloseLast[$fs]=$ops;
      $lustreCltCloseTot+=$lustreCltClose[$fs];
    }
    elsif ($name=~/seek/)
    {
      $lustreCltSeek[$fs]=fix($ops-$lustreCltSeekLast[$fs]);
      $lustreCltSeekLast[$fs]=$ops;
      $lustreCltSeekTot+=$lustreCltSeek[$fs];
    }
    elsif ($name=~/fsync/)
    {
      $lustreCltFsync[$fs]=fix($ops-$lustreCltFsyncLast[$fs]);
      $lustreCltFsyncLast[$fs]=$ops;
      $lustreCltFsyncTot+=$lustreCltFsync[$fs];
    }
    elsif ($name=~/setattr/)
    {
      $lustreCltSetattr[$fs]=fix($ops-$lustreCltSetattrLast[$fs]);
      $lustreCltSetattrLast[$fs]=$ops;
      $lustreCltSetattrTot+=$lustreCltSetattr[$fs];
    }
    elsif ($name=~/getattr/)
    {
      $lustreCltGetattr[$fs]=fix($ops-$lustreCltGetattrLast[$fs]);
      $lustreCltGetattrLast[$fs]=$ops;
      $lustreCltGetattrTot+=$lustreCltGetattr[$fs];
    }
  }
  elsif ($type=~/LLITE_RA:(\d+)/)
  {
    $fs=$1;
    chomp $data;
    $fs=$CltFSMap[$fs]    if $playback ne '';

    if ($data=~/^pending.* (\d+)/)
    {
      # This is NOT a counter but a meter
      $ops=$1;
      $lustreCltRAPending[$fs]=$ops;
      $lustreCltRAPendingTot+=$lustreCltRAPending[$fs];
    }
    elsif ($data=~/^hits.* (\d+)/)
    {
      $ops=$1;
      $lustreCltRAHits[$fs]=fix($ops-$lustreCltRAHitsLast[$fs]);
      $lustreCltRAHitsLast[$fs]=$ops;
      $lustreCltRAHitsTot+=$lustreCltRAHits[$fs];
    }
    elsif ($data=~/^misses.* (\d+)/)
    {
      $ops=$1;
      $lustreCltRAMisses[$fs]=fix($ops-$lustreCltRAMissesLast[$fs]);
      $lustreCltRAMissesLast[$fs]=$ops;
      $lustreCltRAMissesTot+=$lustreCltRAMisses[$fs];
    }
    elsif ($data=~/^readpage.* (\d+)/)
    {
      $ops=$1;
      $lustreCltRANotCon[$fs]=fix($ops-$lustreCltRANotConLast[$fs]);
      $lustreCltRANotConLast[$fs]=$ops;
      $lustreCltRANotCOnTot+=$lustreCltRANotCon[$fs];
    }
    elsif ($data=~/^miss inside.* (\d+)/)
    {
      $ops=$1;
      $lustreCltRAMisWin[$fs]=fix($ops-$lustreCltRAMisWinLast[$fs]);
      $lustreCltRAMisWinLast[$fs]=$ops;
      $lustreCltRAMisWinTot+=$lustreCltRAMisWin[$fs];
    }
    elsif ($data=~/^failed lock.* (\d+)/)
    {
      $ops=$1;
      $lustreCltRALckFail[$fs]=fix($ops-$lustreCltRALckFailLast[$fs]);
      $lustreCltRALckFailLast[$fs]=$ops;
      $lustreCltRALckFailTot+=$lustreCltRALckFail[$fs];
    }
    elsif ($data=~/^read but.* (\d+)/)
    {
      $ops=$1;
      $lustreCltRAReadDisc[$fs]=fix($ops-$lustreCltRAReadDiscLast[$fs]);
      $lustreCltRAReadDiscLast[$fs]=$ops;
      $lustreCltRAReadDiscTot+=$lustreCltRAReadDisc[$fs];
    }
    elsif ($data=~/^zero length.* (\d+)/)
    {
      $ops=$1;
      $lustreCltRAZeroLen[$fs]=fix($ops-$lustreCltRAZeroLenLast[$fs]);
      $lustreCltRAZeroLenPLast[$fs]=$ops;
      $lustreCltRAZeroLenTot+=$lustreCltRAZeroLen[$fs];
    }
    elsif ($data=~/^zero size.* (\d+)/)
    {
      $ops=$1;
      $lustreCltRAZeroWin[$fs]=fix($ops-$lustreCltRAZeroWinLast[$fs]);
      $lustreCltRAZeroWinLast[$fs]=$ops;
      $lustreCltRAZeroWinTot+=$lustreCltRAZeroWin[$fs];
    }
    elsif ($data=~/^read-ahead.* (\d+)/)
    {
      $ops=$1;
      $lustreCltRA2Eof[$fs]=fix($ops-$lustreCltRA2EofLast[$fs]);
      $lustreCltRA2EofLast[$fs]=$ops;
      $lustreCltRA2EofTot+=$lustreCltRA2Eof[$fs];
    }
    elsif ($data=~/^hit max.* (\d+)/)
    {
      $ops=$1;
      $lustreCltRAHitMax[$fs]=fix($ops-$lustreCltRAHitMaxLast[$fs]);
      $lustreCltRAHitMaxLast[$fs]=$ops;
      $lustreCltRAHitMaxTot+=$lustreCltRAHitMax[$fs];
    }
  }
  elsif ($type=~/LLITE_RPC:(\d+):(\d+)/)
  {
    chomp $data;
    $index=$1;
    $bufNum=$2;

    ($lustreCltRpcReadNow, $lustreCltRpcWriteNow)=(split(/\s+/, $data))[1,5];
    $index=$CltOstMap[$index]    if $playback ne '';

    $lustreCltRpcRead[$index][$bufNum]= fix($lustreCltRpcReadNow-$lustreCltRpcReadLast[$index][$bufNum]);
    $lustreCltRpcWrite[$index][$bufNum]=fix($lustreCltRpcWriteNow-$lustreCltRpcWriteLast[$index][$bufNum]);

    $lustreCltRpcReadTot[$bufNum]+= $lustreCltRpcRead[$index][$bufNum];
    $lustreCltRpcWriteTot[$bufNum]+=$lustreCltRpcWrite[$index][$bufNum];

    $lustreCltRpcReadLast[$index][$bufNum]= $lustreCltRpcReadNow;
    $lustreCltRpcWriteLast[$index][$bufNum]=$lustreCltRpcWriteNow;
  }
  elsif ($type=~/LLDET:(\d+)/)
  {
    $ost=$1;
    chomp $data;
    ($name, $ops, $value)=(split(/\s+/, $data))[0,1,6];
    $ost=$CltOstMap[$ost]    if $playback ne '';

    if ($name=~/ost_r/)
    {
      $lustreCltLunRead[$ost]=fix($ops-$lustreCltLunReadLast[$ost]);
      $lustreCltLunReadLast[$ost]=$ops;
      if (defined($value))  # not always defined
      {
        $lustreCltLunReadKB[$ost]=fix($value-$lustreCltLunReadKBLast[$ost]);
        $lustreCltLunReadKBLast[$ost]=$value;
      }
    }
    elsif ($name=~/ost_w/)
    {
      $lustreCltLunWrite[$ost]=fix($ops-$lustreCltLunWriteLast[$ost]);
      $lustreCltLunWriteLast[$ost]=$ops;
      if (defined($value))  # not always defined
      {
        $lustreCltLunWriteKB[$ost]=fix($value-$lustreCltLunWriteKBLast[$ost]);
        $lustreCltLunWriteKBLast[$ost]=$value;
      }
    }
  }

  # disk stats apply to both MDS and OSTs
  elsif ($type=~/LUS-d_(\d+):(\d+)/)
  {
    $lusDisk=$1;
    $bufNum= $2;

    # The units of 'readB/writeB' are number of 512 byte blocks
    # in case partial table [rare], make sure totals go in last bucket.
    chomp $data;
    ($size, $reads, $readB, $writes, $writeB)=split(/\s+/, $data);
    $bufNum=$LusMaxIndex    if $size=~/^total/;

    # Numbers for individual disks
    $lusDiskReads[$lusDisk][$bufNum]= fix($reads-$lusDiskReadsLast[$lusDisk][$bufNum]);
    $lusDiskReadB[$lusDisk][$bufNum]= fix($readB-$lusDiskReadBLast[$lusDisk][$bufNum]);
    $lusDiskWrites[$lusDisk][$bufNum]=fix($writes-$lusDiskWritesLast[$lusDisk][$bufNum]);
    $lusDiskWriteB[$lusDisk][$bufNum]=fix($writeB-$lusDiskWriteBLast[$lusDisk][$bufNum]);
    #print "BEF DISKTOT[$bufNum]  R: $lusDiskReadsTot[$bufNum]  W: $lusDiskWritesTot[$bufNum]\n";

    # Numbers for ALL disks
    $lusDiskReadsTot[$bufNum]+= $lusDiskReads[$lusDisk][$bufNum];
    $lusDiskReadBTot[$bufNum]+= $lusDiskReadB[$lusDisk][$bufNum];
    $lusDiskWritesTot[$bufNum]+=$lusDiskWrites[$lusDisk][$bufNum];
    $lusDiskWriteBTot[$bufNum]+=$lusDiskWriteB[$lusDisk][$bufNum];
    #print "AFT DISKTOT[$bufNum]  R: $lusDiskReadsTot[$bufNum]  W: $lusDiskWritesTot[$bufNum]\n";

    $lusDiskReadsLast[$lusDisk][$bufNum]= $reads;
    $lusDiskReadBLast[$lusDisk][$bufNum]= $readB;
    $lusDiskWritesLast[$lusDisk][$bufNum]=$writes;
    $lusDiskWriteBLast[$lusDisk][$bufNum]=$writeB;
    #print "DISK[$lusDisk][$bufNum]  R: $lusDiskReads[$lusDisk][$bufNum]  W: $lusDiskWrites[$lusDisk][$bufNum]\n";
  }

  elsif ($type=~/^intr/ && $subsys=~/c/)
  {
    $intrptNow=$data;
    $intrpt=fix($intrptNow-$intrptLast);
    $intrptLast=$intrptNow;
  }

  elsif ($type=~/^ctx/ && $subsys=~/c/)
  {
    $ctxtNow=$data;
    $ctxt=fix($ctxtNow-$ctxtLast);
    $ctxtLast=$ctxtNow;
  }

  elsif ($type=~/^proce/ && $subsys=~/c/)
  {
    $procNow=$data;
    $proc=fix($procNow-$procLast);
    $procLast=$procNow;
  }

  elsif ($type=~/^fan/ && $subsys=~/E/)
  {
    $interval3Print=1;
    ($fanNum, $fanStat, $fanText)=split(/\s+/, $data);
    $fanStat[$fanNum]=$fanStat;
    $fanText[$fanNum]=$fanText;
  }

  elsif ($type=~/^pwr/ && $subsys=~/E/)
  {
    $interval3Print=1;
    ($pwrNum, $pwrStat)=split(/\s+/, $data);
    $pwrStat[$pwrNum]=$pwrStat;
  }

  elsif ($type=~/^temp/ && $subsys=~/E/)
  { 
    $interval3Print=1;
    ($tempNum, $tempTemp)=split(/\s+/, $data);
    $tempTemp[$tempNum]=$tempTemp;
  }

  elsif ($type=~/^disk|^par/ && $subsys=~/d/i)
  {
    if ($kernel2_4 && $type=~/disk/)  # data must be in /proc/stat
    {
      @disks=split(/\s+/, $data);
      foreach $disk (@disks)
      {
        $details=(split(/:/, $disk))[1];
        ($dskOpsNow, $dskReadNow, $dskReadSectNow, $dskWriteNow, $dskWriteSectNow)=split(/,/, $details);
        if (!defined($dskWriteSectNow))
        {
	  incomplete("DISK:".$dskName[$dskIndex], $lastSecs);
	  $dskIndex++;
          next;
        }

        $dskOpsNow=~s/\(//;
        $dskWriteSectNow=~s/\)//;

        $dskReadKBNow= $dskReadSectNow/2;
        $dskWriteKBNow=$dskWriteSectNow/2;

        $dskOps[$dskIndex]=    fix($dskOpsNow-$dskOpsLast[$dskIndex]);
        $dskRead[$dskIndex]=   fix($dskReadNow-$dskReadLast[$dskIndex]);
        $dskReadKB[$dskIndex]= fix($dskReadKBNow-$dskReadKBLast[$dskIndex]);
        $dskWrite[$dskIndex]=  fix($dskWriteNow-$dskWriteLast[$dskIndex]);
        $dskWriteKB[$dskIndex]=fix($dskWriteKBNow-$dskWriteKBLast[$dskIndex]);

        $dskOpsTot+=    $dskOps[$dskIndex];
        $dskReadTot+=   $dskRead[$dskIndex];
        $dskReadKBTot+= $dskReadKB[$dskIndex];
        $dskWriteTot+=  $dskWrite[$dskIndex];
        $dskWriteKBTot+=$dskWriteKB[$dskIndex];

        $dskOpsLast[$dskIndex]=    $dskOpsNow;
        $dskReadLast[$dskIndex]=   $dskReadNow;
        $dskReadKBLast[$dskIndex]= $dskReadKBNow;
        $dskWriteLast[$dskIndex]=  $dskWriteNow;
        $dskWriteKBLast[$dskIndex]=$dskWriteKBNow;

        $dskIndex++;
      }
    }
    else
    {
      # data must be in /proc/partitions OR /proc/diskstats 
      @dskFields=(split(/\s+/, $data))[4..14]    if $kernel2_4;
      @dskFields=(split(/\s+/, $data))[3..13]    if $kernel2_6;

      # Clarification of field definitions:
      # Excellent reference: http://cvs.sourceforge.net/viewcvs.py/linux-vax
      #                               /kernel-2.5/Documentation/iostats.txt?rev=1.1.1.2
      #   ticks - time in jiffies doing I/O (some utils call it 'r/w-use')
      #   inprog - I/O's in progress (some utils call it 'running')
      #   ticks - time actually spent doing I/O (some utils call it 'use')
      #   aveque - average time in queue (some utils call it 'aveq' or even 'ticks')
      $dskRead[$dskIndex]=      fix($dskFields[0]-$dskFieldsLast[$dskIndex][0]);
      $dskReadMrg[$dskIndex]=   fix($dskFields[1]-$dskFieldsLast[$dskIndex][1]);
      $dskReadKB[$dskIndex]=    fix($dskFields[2]-$dskFieldsLast[$dskIndex][2])/2;
      $dskReadTicks[$dskIndex]= fix($dskFields[3]-$dskFieldsLast[$dskIndex][3]);
      $dskWrite[$dskIndex]=     fix($dskFields[4]-$dskFieldsLast[$dskIndex][4]);
      $dskWriteMrg[$dskIndex]=  fix($dskFields[5]-$dskFieldsLast[$dskIndex][5]);
      $dskWriteKB[$dskIndex]=   fix($dskFields[6]-$dskFieldsLast[$dskIndex][6])/2;
      $dskWriteTicks[$dskIndex]=fix($dskFields[7]-$dskFieldsLast[$dskIndex][7]);
      $dskInProg[$dskIndex]=    $dskFieldsLast[$dskIndex][8];
      $dskTicks[$dskIndex]=     fix($dskFields[9]-$dskFieldsLast[$dskIndex][9]);

      # according to the author of iostat this field can sometimes be negative
      # so handle the same way he does
      $dskWeighted[$dskIndex]=($dskFields[10]>=$dskFieldsLast[$dskIndex][10]) ?
		  fix($dskFields[10]-$dskFieldsLast[$dskIndex][10]) :
		  fix($dskFieldsLast[$dskIndex][10]-$dskFields[10]);

      # Don't include device mapper data in totals
      if ($dskName[$dskIndex]!~/^dm-/)
      {
        $dskReadTot+=      $dskRead[$dskIndex];
        $dskReadMrgTot+=   $dskReadMrg[$dskIndex];
        $dskReadKBTot+=    $dskReadKB[$dskIndex];
        $dskReadTicksTot+= $dskReadTicks[$dskIndex];
        $dskWriteTot+=     $dskWrite[$dskIndex];
        $dskWriteMrgTot+=  $dskWriteMrg[$dskIndex];
        $dskWriteKBTot+=   $dskWriteKB[$dskIndex];
        $dskWriteTicksTot+=$dskWriteTicks[$dskIndex];
      }

      # needed for compatibility with 2.4 in -P output
      $dskOpsTot=$dskReadTot+$dskWriteTot;

      # we only need these if doing individual disk calculations
      if ($subsys=~/D/)
      {
        $numIOs=$dskRead[$dskIndex]+$dskWrite[$dskIndex];
        $dskRqst[$dskIndex]=   $numIOs ? ($dskReadKB[$dskIndex]+$dskWriteKB[$dskIndex])/$numIOs : 0;
        $dskQueLen[$dskIndex]= $dskWeighted[$dskIndex]/$microInterval*$HZ/1000;
        $dskWait[$dskIndex]=   $numIOs ? ($dskReadTicks[$dskIndex]+$dskWriteTicks[$dskIndex])/$numIOs : 0;
        $dskSvcTime[$dskIndex]=$numIOs ? $dskTicks[$dskIndex]/$numIOs : 0;
        $dskUtil[$dskIndex]=   $dskTicks[$dskIndex]*10/$microInterval;
      }

      # note fieldsLast[8] ignored
      for ($i=0; $i<11; $i++)
      {
	$dskFieldsLast[$dskIndex][$i]=$dskFields[$i];
      }
      $dskIndex++;
    }
  }

  elsif ($type=~/^fs-/ && $subsys=~/i/)
  {
    if ($type=~/^fs-ds/)
    {
      $unusedDCache=(split(/\s+/, $data))[1];
    }
    elsif ($type=~/^fs-fnr/)
    {
      ($openFiles)=(split(/\s+/, $data))[1];
    }
    elsif ($type=~/^fs-is/)
    {
      ($inodeUsed, $param)=split(/\s+/, $data);
      $inodeUsed-=$param;
    }
    elsif ($type=~/^fs-snr/)
    {
      $superUsed=($SBMax) ? $data : 0;   # only meaningful if $superMax
    }
    elsif ($type=~/^fs-dqnr/)
    {
      $dquotUsed=($DQMax) ? (split(/\s+/, $data))[0] : 0;  # needs $dquotMax
    }
  }

  # this only applies to nfs server
  elsif ($type=~/^nfs-net/ && $subsys=~/f/i)
  {
    ($nfsPktsNow, $nfsUdpNow, $nfsTcpNow, $nfsTcpConnNow)=split(/\s+/, $data);
    if (!defined($nfsTcpConnNow))
    {
      incomplete("NFS-NET", $lastSecs);
      return;
    }

    $nfsPkts=   fix($nfsPktsNow-$nfsPktsLast);
    $nfsUdp=    fix($nfsUdpNow-$nfsUdpLast);
    $nfsTcp=    fix($nfsTcpNow-$nfsTcpLast);
    $nfsTcpConn=fix($nfsTcpConnNow-$nfsTcpConnLast);

    $nfsPktsLast=   $nfsPktsNow;
    $nfsUdpLast=    $nfsUdpNow;
    $nfsTcpLast=    $nfsTcpNow;
    $nfsTcpConnLast=$nfsTcpConnNow;
  }

  # nfs rpc for server doesn't use fields 2/5
  elsif ($type=~/^nfs-rpc/ && $subsys=~/f/i && $subOpts!~/C/)
  {
    ($rpcCallsNow, $rpcBadAuthNow, $rpcBadClntNow)=(split(/\s+/, $data))[0,2,3];
    if (!defined($rpcBadClntNow))
    {
      incomplete("RPC", $lastSecs);
      return;
    }

    $rpcCalls=   fix($rpcCallsNow-$rpcCallsLast);
    $rpcBadAuth= fix($rpcBadAuthNow-$rpcBadAuthLast);
    $rpcBadClnt= fix($rpcBadClntNow-$rpcBadClntLast);

    $rpcCallsLast=  $rpcCallsNow;
    $rpcBadAuthLast=$rpcBadAuthNow;
    $rpcBadClntLast=$rpcBadClntNow;
  }

  # nfs rpc for client used everything, but different meanings
  elsif ($type=~/^nfs-rpc/ && $subsys=~/f/i && $subOpts=~/C/)
  {
    ($rpcCallsNow, $rpcRetransNow, $rpcCredRefNow)=split(/\s+/, $data);
    if (!defined($rpcCredRefNow))
    {
      incomplete("RPC", $lastSecs);
      return;
    }

    $rpcCalls=  fix($rpcCallsNow-$rpcCallsLast);
    $rpcRetrans=fix($rpcRetransNow-$rpcRetransLast);
    $rpcCredRef=fix($rpcCredRefNow-$rpcCredRefLast);

    $rpcCallsLast=  $rpcCallsNow;
    $rpcRetransLast=$rpcRetransNow;
    $rpcCredRefLast=$rpcCredRefNow;
  }

  elsif ($type=~/^nfs-proc2/ && $subsys=~/f/i)
  {
    # field 0 is field count, which we know to be 18
    @nfs2ValuesNow=(split(/\s+/, $data))[1..18];
    if (scalar(@nfs2ValuesNow)<18)
    {
      incomplete("NFS2", $lastSecs);
      return;
    }

    # a lot less typing.
    for ($i=0; $i<18; $i++)
    {
      $nfs2Value[$i]=fix($nfs2ValuesNow[$i]-$nfs2ValuesLast[$i]);
      $nfs2ValuesLast[$i]=$nfs2ValuesNow[$i];
    }

    $nfs2Null=$nfs2Value[0];       $nfs2Getattr=$nfs2Value[1];
    $nfs2Setattr=$nfs2Value[2];    $nfs2Root=$nfs2Value[3];
    $nfs2Lookup=$nfs2Value[4];     $nfs2Readlink=$nfs2Value[5];
    $nfs2Read=$nfs2Value[6];       $nfs2Wrcache=$nfs2Value[7];
    $nfs2Write=$nfs2Value[8];      $nfs2Create=$nfs2Value[9];
    $nfs2Remove=$nfs2Value[10];    $nfs2Rename=$nfs2Value[11];
    $nfs2Link=$nfs2Value[12];      $nfs2Symlink=$nfs2Value[13];
    $nfs2Mkdir=$nfs2Value[14];     $nfs2Rmdir=$nfs2Value[15];
    $nfs2Readdir=$nfs2Value[16];   $nfs2Fsstat=$nfs2Value[17];
  }

  elsif ($type=~/^nfs-proc3/ && $subsys=~/f/i)
  {
    # field 0 is field count
    @nfsValuesNow=(split(/\s+/, $data))[1..22];
    if (scalar(@nfsValuesNow)<22)
    {
      incomplete("NFS3", $lastSecs);
      return;
    }

    # a lot less typing.
    for ($i=0; $i<22; $i++)
    {
      $nfsValue[$i]=fix($nfsValuesNow[$i]-$nfsValuesLast[$i]);
      $nfsValuesLast[$i]=$nfsValuesNow[$i];
    }

    $nfsNull=$nfsValue[0];       $nfsGetattr=$nfsValue[1];
    $nfsSetattr=$nfsValue[2];    $nfsLookup=$nfsValue[3];
    $nfsAccess=$nfsValue[4];     $nfsReadlink=$nfsValue[5];
    $nfsRead=$nfsValue[6];       $nfsWrite=$nfsValue[7];
    $nfsCreate=$nfsValue[8];     $nfsMkdir=$nfsValue[9];
    $nfsSymlink=$nfsValue[10];   $nfsMknod=$nfsValue[11];
    $nfsRemove=$nfsValue[12];    $nfsRmdir=$nfsValue[13];
    $nfsRename=$nfsValue[14];    $nfsLink=$nfsValue[15];
    $nfsReaddir=$nfsValue[16];   $nfsReaddirplus=$nfsValue[17];
    $nfsFsstat=$nfsValue[18];    $nfsFsinfo=$nfsValue[19];
    $nfsPathconf=$nfsValue[20];  $nfsCommit=$nfsValue[21];
  }

  #    M e m o r y    S t a t s    -    2 . 4    K e r n e l

  elsif ($type=~/^page/ && $subsys=~/m/)
  {
    ($pageinNow, $pageoutNow)=split(/\s+/, $data);

    $pagein= fix($pageinNow- $pageinLast);
    $pageout=fix($pageoutNow-$pageoutLast);

    $pageinLast= $pageinNow;
    $pageoutLast=$pageoutNow;
  }

  elsif ($type=~/^swap/ && $subsys=~/m/)
  {
    ($swapinNow, $swapoutNow)=split(/\s+/, $data);

    $swapin= fix($swapinNow- $swapinLast);
    $swapout=fix($swapoutNow-$swapoutLast);

    $swapinLast= $swapinNow;
    $swapoutLast=$swapoutNow;
  }

  elsif ($type=~/^Mem:/ && $subsys=~/m/)
  {
    ($memTot, $memUsed, $memFree, $memShared, $memBuf)=split(/\s+/, $data);
    $memTot/=$OneKB;
    $memUsed/=$OneKB;
    $memFree/=$OneKB;
    $memShared/=$OneKB;
    $memBuf/=$OneKB;
  }
  elsif ($type=~/^Cached/ && $subsys=~/m/)
  {
    ($memCached)=split(/\s+/, $data);
  }

  elsif ($type=~/^Swap:/ && $subsys=~/m/)
  {
    ($swapTotal, $swapUsed, $swapFree)=split(/\s+/, $data);
    $swapTotal/=$OneKB;
    $swapUsed/=$OneKB;
    $swapFree/=$OneKB;
  }

  elsif ($type=~/^Active|^Inact/ && $subsys=~/m/ && $kernel2_4)
  {
    $active=(split(/\s+/, $data))[0]    if $type=~/^Active/;
    $dirty=(split(/\s+/, $data))[0]     if $type=~/^Inact_dirty/;
    $laundry=(split(/\s+/, $data))[0]   if $type=~/^Inact_laundry/;
    $clean=(split(/\s+/, $data))[0]     if $type=~/^Inact_clean/;
    $target=(split(/\s+/, $data))[0]    if $type=~/^Inact_target/;
    $inactive=(split(/\s+/, $data))[0]  if $type=~/^Inactive/;
  }

  #    M e m o r y    S t a t s    -    2 . 6    K e r n e l

  elsif ($type=~/^pgpg|^pswp/ && $subsys=~/m/)
  {
    if ($type=~/^pgpgin/)
    {
      $pageinNow=$data;
      $pagein=fix($pageinNow-$pageinLast);
      $pageinLast=$pageinNow;
    }
    if ($type=~/^pgpgout/)
    {
      $pageoutNow=$data;
      $pageout=fix($pageoutNow-$pageoutLast);
      $pageoutLast=$pageoutNow;
    }
    if ($type=~/^pswpin/)
    {
      $swapinNow=$data;
      $swapin=fix($swapinNow-$swapinLast);
      $swapinLast=$swapinNow;
    }
    if ($type=~/^pswpout/)
    {
      $swapoutNow=$data;
      $swapout=fix($swapoutNow-$swapoutLast);
      $swapoutLast=$swapoutNow;
    }
  }

  elsif ($type=~/^Mem/ && $subsys=~/m/ && $kernel2_6)
  {
    $data=(split(/\s+/, $data))[0];
    $memTot= $data    if $type=~/^MemTotal/;
    $memFree=$data    if $type=~/^MemFree/;
  }

  elsif ($type=~/^Buffers|^Cached|^Dirty|^Active|^Inactive|^Mapped|^Slab:|^Committed_AS:/ && $subsys=~/m/ && $kernel2_6)
  {
    $data=(split(/\s+/, $data))[0];
    $memBuf=$data       if $type=~/^Buf/;
    $memCached=$data    if $type=~/^Cac/;
    $dirty=$data        if $type=~/^Dir/;
    $active=$data       if $type=~/^Act/;
    $inactive=$data     if $type=~/^Ina/;
    $memSlab=$data      if $type=~/^Sla/;
    $memMap=$data       if $type=~/^Map/;
    $memCommit=$data    if $type=~/^Com/;
   }

  elsif ($type=~/^procs/ && $subsys=~/m/ && $kernel2_6)
  {
    # never include outselves in count of running processes
    $data=(split(/\s+/, $data))[0];
    $procsRun=$data-1     if $type=~/^procs_r/;
    $procsBlock=$data     if $type=~/^procs_b/;
  }

  elsif ($type=~/^Swap/ && $subsys=~/m/ && $kernel2_6)
  {
    $data=(split(/\s+/, $data))[0];
    $swapTotal=$data    if $type=~/^SwapT/;
    $swapFree=$data     if $type=~/^SwapF/;
    $swapCached=$data   if $type=~/^SwapC/;
  }

  #    S o c k e t    S t a t s

  elsif ($type=~/^sock/ && $subsys=~/s/)
  {
    if ($data=~/^sock/)
    {
      $data=~/(\d+)$/;
      $sockUsed=$1;
    }
    elsif ($data=~/^TCP/)
    {
      ($sockTcp, $sockOrphan, $sockTw, $sockAlloc, $sockMem)=
		(split(/\s+/, $data))[2,4,6,8,10];
    }
    elsif ($data=~/^UDP/)
    {
      $data=~/(\d+)$/;
      $sockUdp=$1;
    }
    elsif ($data=~/^RAW/)
    {
      $data=~/(\d+)$/;
      $sockRaw=$1;
    }
    elsif ($data=~/^FRAG/)
    {
      $data=~/(\d+).*(\d)$/;
      $sockFrag=$1;
      $sockFragM=$1;
    }
  }

  #    N e t w o r k    S t a t s

  elsif ($type=~/^Net/ && $subsys=~/n/i)
  {
    # insert space after interface if none already there
    $data=~s/:(\d)/: $1/;
    undef @fields;
    @fields=split(/\s+/, $data);

    # In rare occasions a new network device shows up so we need to make sure we init
    # the appropriate variables
    if (!defined($netRxKBLast[$netIndex]))
    {
      $NumNets++;
      $netName=(split(/\s+/, $line))[1];
      $netRxKBLast[$netIndex]=$netRxPktLast[$netIndex]=$netTxKBLast[$netIndex]=$netTxPktLast[$netIndex]=0;
      $netRxErrLast[$netIndex]=$netRxDrpLast[$netIndex]=$netRxFifoLast[$netIndex]=$netRxFraLast[$netIndex]=0;
      $netRxCmpLast[$netIndex]=$netRxMltLast[$netIndex]=$netTxCarLast[$netIndex]=$netTxCmpLast[$netIndex]=0;
      $netTxErrLast[$netIndex]=$netTxDrpLast[$netIndex]=$netTxFifoLast[$netIndex]=$netTxCollLast[$netIndex]=0;
      $NetMaxTraffic[$netIndex]=2*$interval*$DefNetSpeed*125;
      logmsg("W", "New network device found: $netName");
    }

    if (scalar(@fields)<17)
    {
      incomplete("NET:".$fields[0], $lastSecs);
      $netIndex++;
      return;
    }

    $netNameNow=  $fields[0];
    $netRxKBNow=  $fields[1];
    $netRxPktNow= $fields[2];
    $netRxErrNow= $fields[3];
    $netRxDrpNow= $fields[4];
    $netRxFifoNow=$fields[5];
    $netRxFraNow= $fields[6];
    $netRxCmpNow= $fields[7];
    $netRxMltNow= $fields[8];

    $netTxKBNow=  $fields[9];
    $netTxPktNow= $fields[10];
    $netTxErrNow= $fields[11];
    $netTxDrpNow= $fields[12];
    $netTxFifoNow=$fields[13];
    $netTxCollNow=$fields[14];
    $netTxCarNow= $fields[15];
    $netTxCmpNow= $fields[16];

    # It has occasionally been observed that bogus data is returned for some networks.
    # If we see anything that looks like twice the typical speed, ignore it but remember
    # that during the very first interval this data should be bogus!
    my $netRxKBTemp=fix($netRxKBNow-$netRxKBLast[$netIndex])/1024;
    my $netTxKBTemp=fix($netTxKBNow-$netTxKBLast[$netIndex])/1024;
    if ($intervalCounter &&  
         ($netRxKBTemp>$NetMaxTraffic[$netIndex] || $netTxKBTemp>$NetMaxTraffic[$netIndex]))
    {
      #print "$netNameNow TxNOW: $netTxKBNow LAST: $netTxKBLast[$netIndex]\n";
      #print "$netNameNow RX: $netRxKBTemp TX: $netTxKBTemp  MAX: $NetMaxTraffic[$netIndex]\n";
      incomplete("NET:".$netNameNow, $lastSecs, 'Bogus');
      logmsg('I', "Bogus Value(s) for $netNameNow - TX: $netTxKBTemp  RX: $netRxKBTemp");
      $netIndex++; 
      return;
    }

    $netRxKB[$netIndex]= $netRxKBTemp;
    $netTxKB[$netIndex]= $netTxKBTemp;
    $netRxPkt[$netIndex]=fix($netRxPktNow-$netRxPktLast[$netIndex]);
    $netTxPkt[$netIndex]=fix($netTxPktNow-$netTxPktLast[$netIndex]);

    # extended/errors
    $netRxErr[$netIndex]= fix($netRxErrNow- $netRxErrLast[$netIndex]);
    $netRxDrp[$netIndex]= fix($netRxDrpNow- $netRxDrpLast[$netIndex]);
    $netRxFifo[$netIndex]=fix($netRxFifoNow-$netRxFifoLast[$netIndex]);
    $netRxFra[$netIndex]= fix($netRxFraNow- $netRxFraLast[$netIndex]);
    $netRxCmp[$netIndex]= fix($netRxCmpNow- $netRxCmpLast[$netIndex]);
    $netRxMlt[$netIndex]= fix($netRxMltNow- $netRxMltLast[$netIndex]);
    $netTxErr[$netIndex]= fix($netTxErrNow- $netTxErrLast[$netIndex]);
    $netTxDrp[$netIndex]= fix($netTxDrpNow- $netTxDrpLast[$netIndex]);
    $netTxFifo[$netIndex]=fix($netTxFifoNow-$netTxFifoLast[$netIndex]);
    $netTxColl[$netIndex]=fix($netTxCollNow-$netTxCollLast[$netIndex]);
    $netTxCar[$netIndex]= fix($netTxCarNow- $netTxCarLast[$netIndex]);
    $netTxCmp[$netIndex]= fix($netTxCmpNow- $netTxCmpLast[$netIndex]);

    # these are derived for simplicity of plotting
    $netRxErrs[$netIndex]=$netRxErr[$netIndex]+$netRxDrp[$netIndex]+
			  $netRxFifo[$netIndex]+$netRxFra[$netIndex];
    $netTxErrs[$netIndex]=$netTxErr[$netIndex]+$netTxDrp[$netIndex]+
			  $netTxFifo[$netIndex]+$netTxColl[$netIndex]+
			  $netTxCar[$netIndex];

    # Ethernet totals only
    if ($netNameNow=~/eth/)
    {
      $netEthRxKBTot+= $netRxKB[$netIndex];
      $netEthRxPktTot+=$netRxPkt[$netIndex];
      $netEthTxKBTot+= $netTxKB[$netIndex];
      $netEthTxPktTot+=$netTxPkt[$netIndex];
    }

    # at least for now, we're only worrying about totals on real network
    # devices and loopback and sit are certainly not them.
    if ($netNameNow!~/lo|sit/)
    {
      $netRxKBTot+= $netRxKB[$netIndex];
      $netRxPktTot+=$netRxPkt[$netIndex];
      $netTxKBTot+= $netTxKB[$netIndex];
      $netTxPktTot+=$netTxPkt[$netIndex];

      $netRxErrTot+= $netRxErr[$netIndex];
      $netRxDrpTot+= $netRxDrp[$netIndex];
      $netRxFifoTot+=$netRxFifo[$netIndex];
      $netRxFraTot+= $netRxFra[$netIndex];
      $netRxCmpTot+= $netRxCmp[$netIndex];
      $netRxMltTot+= $netRxMlt[$netIndex];
      $netTxErrTot+= $netTxErr[$netIndex];
      $netTxDrpTot+= $netTxDrp[$netIndex];
      $netTxFifoTot+=$netTxFifo[$netIndex];
      $netTxCollTot+=$netTxColl[$netIndex];
      $netTxCarTot+= $netTxCar[$netIndex];
      $netTxCmpTot+= $netTxCmp[$netIndex];

      $netRxErrsTot+=$netRxErrs[$netIndex];
      $netTxErrsTot+=$netTxErrs[$netIndex];
    }

    $netName[$netIndex]=     $netNameNow;
    $netRxKBLast[$netIndex]= $netRxKBNow;
    $netRxPktLast[$netIndex]=$netRxPktNow;
    $netTxKBLast[$netIndex]= $netTxKBNow;
    $netTxPktLast[$netIndex]=$netTxPktNow;

    $netRxErrLast[$netIndex]=$netRxErrNow;
    $netRxDrpLast[$netIndex]=$netRxDrpNow;
    $netRxFifoLast[$netIndex]=$netRxFifoNow;
    $netRxFraLast[$netIndex]=$netRxFraNow;
    $netRxCmpLast[$netIndex]=$netRxCmpNow;
    $netRxMltLast[$netIndex]=$netRxMltNow;
    $netTxErrLast[$netIndex]=$netTxErrNow;
    $netTxDrpLast[$netIndex]=$netTxDrpNow;
    $netTxFifoLast[$netIndex]=$netTxFifoNow;
    $netTxCollLast[$netIndex]=$netTxCollNow;
    $netTxCarLast[$netIndex]=$netTxCarNow;
    $netTxCmpLast[$netIndex]=$netTxCmpNow;

    $netIndex++;
  }

  #    N e t w o r k    S t a t s

  elsif ($type=~/^TcpExt/ && $subsys=~/t/i)
  {
    chomp $data;
    @tcpFields=split(/ /, $data);
    for ($i=0; $i<$NumTcpFields; $i++)
    {
      $tcpValue[$i]=fix($tcpFields[$i]-$tcpLast[$i]);
      $tcpLast[$i]=$tcpFields[$i];
      #print "$i: $tcpValue[$i] ";
    }
  }

  #    E L A N    S t a t s

  # we have to test the subsys first becaue $1 gets trashed if first
  elsif ($subsys=~/x/i && $type=~/^Elan(\d+)/)
  {
    $i=$1;
    if ($XVersion lt '5.20.0')
    {
      ($name, $value)=(split(/\s+/, $data))[0,1]    if $XVersion;
    }
    else
    {
      ($value, $name)=(split(/\s+/, $data))[0,1]    if $XVersion;
    }

    if ($value=~/^Send/ || $name=~/^Send/)
    {
      ($elanSendFail, $elanNeterrAtomic, $elanNeterrDma)=(split(/\s+/, $data))[1,3,5];
      $elanSendFail[$i]=    fix($elanSendFail-$elanSendFailLast[$i]);
      $elanNeterrAtomic[$i]=fix($elanNeterrAtomic-$elanNeterrAtomicLast[$i]);
      $elanNeterrDma[$i]=   fix($elanNeterrDma-$elanNeterrDmaLast[$i]);

      $elanSendFailTot+=    $elanSendFail[$i];
      $elanNeterrAtomicTot+=$elanNeterrAtomic[$i];
      $elanNeterrDmaTot+=   $elanNeterrDma[$i];

      $elanSendFailLast[$i]=    $elanSendFail;
      $elanNeterrAtomicLast[$i]=$elanNeterrAtomic;
      $elanNeterrDmaLast[$i]=   $elanNeterrDma;
    }
    elsif ($name=~/^Rx/)
    {  
      $elanRx[$i]=    fix($value-$elanRxLast[$i]);
      $elanRxLast[$i]=$value;
      $elanRxTot=     $elanRx[$i];
      $elanRxFlag=1;
      $elanTxFlag=$elanPutFlag=$elanGetFlag=$elanCompFlag=0;
    }
    elsif ($name=~/^Tx/)
    {
      $elanTx[$i]=    fix($value-$elanTxLast[$i]);
      $elanTxLast[$i]=$value;
      $elanTxTot=     $elanTx[$i];
      $elanTxFlag=1;
      $elanRxFlag=$elanPutFlag=$elanGetFlag=$elanCompFlag=0;
    }
    elsif ($name=~/^Put/)
    {
      $elanPut[$i]=    fix($value-$elanPutLast[$i]);
      $elanPutLast[$i]=$value;
      $elanPutTot=     $elanPut[$i];
      $elanPutFlag=1;
      $elanTxFlag=$elanRxFlag=$elanGetFlag=$elanCompFlag=0;
    }
    elsif ($name=~/^Get/)
    {
      $elanGet[$i]=    fix($value-$elanGetLast[$i]);
      $elanGetLast[$i]=$value;
      $elanGetTot=     $elanGet[$i];
      $elanGetFlag=1;
      $elanTxFlag=$elanRxFlag=$elanPutFlag=$elanCompFlag=0;
    }
    elsif ($name=~/^Comp/)
    {
      $elanComp[$i]=    fix($value-$elanCompLast[$i]);
      $elanCompLast[$i]=$value;
      $elanCompTot=     $elanComp[$i];
      $elanCompFlag=1;
      $elanTxFlag=$elanRxFlag=$elanPutFlag=$elanGetFlag=0;
    }
    elsif ($name=~/^MB/)
    {
      # NOTE - elan reports data in MB but we want it in KB to be
      #        consistent with other interconects
      if ($elanRxFlag)
      {      
        $elanRxMB=        fix($value-$elanRxMBLast[$i], $OneMB);
        $elanRxMBLast[$i]=$value;
        $elanRxKB[$i]=    $elanRxMB*1024;
        $elanRxKBTot=     $elanRxKB[$i];
      }
      elsif ($elanTxFlag)
      {
        $elanTxMB=        fix($value-$elanTxMBLast[$i], $OneMB);
        $elanTxMBLast[$i]=$value;
	$elanTxKB[$i]=    $elanTxMB*1024;
        $elanTxKBTot=     $elanTxKB[$i];
      }
      elsif ($elanPutFlag)
      {      
        $elanPutMB=        fix($value-$elanPutMBLast[$i], $OneMB);
        $elanPutMBLast[$i]=$value;
        $elanPutKB[$i]=    $elanPutMB*1024;
        $elanPutKBTot=     $elanPutKB[$i];
      }
      elsif ($elanGetFlag)
      {      
        $elanGetMB=        fix($value-$elanGetMBLast[$i], $OneMB);
        $elanGetMBLast[$i]=$value;
        $elanGetKB[$i]=    $elanGetMB*1024;
        $elanGetKBTot=     $elanGetKB[$i];
      }
      elsif ($elanCompFlag)
      {      
        $elanCompMB=        fix($value-$elanCompMBLast[$i], $OneMB);
        $elanCompMBLast[$i]=$value;
        $elanCompKB[$i]=    $elanCompMB*1024;
        $elanCompKBTot=     $elanCompKB[$i];
      }
      else
      {
        logmsg("W", "### Found elan MB without type flag set");
      }
    }
  }

  #    I n f i n i b a n d    S t a t s

  # we have to test the subsys first becaue $1 gets trashed if first
  elsif ($subsys=~/x/i && $type=~/^ib(\d+)/)
  {
    $i=$1;
    ($port, @fieldsNow)=(split(/\s+/, $data))[0,4..19];

    # Only 1 of the two ports are actually active at any one time
    if ($HCAPorts[$i][$port])
    {
      # Remember which port is active for sexpr.
      $HCAPortActive=$port;

      # Calculate values for each field based on 'last' values.
      $ibErrorsTot[$i]=0;
      for ($j=0; $j<16; $j++)
      {
        $fields[$j]=fix($fieldsNow[$j]-$ibFieldsLast[$i][$port][$j]);
        $ibFieldsLast[$i][$port][$j]=$fieldsNow[$j];

        # the first 12 are accumulated as a single error count and ultimately
        # reporting as anbsolute number and NOT a rate so don't use 'last'
        $ibErrorsTot[$i]+=$fieldsNow[$j]    if $j<12;
      }

      # Do individual counters, noting that the open fabric one has '-port' appended
      # and that their values are alredy absolute and not incrementing counters that
      # that need to be adjusted agaist previous versions
      if ($type=~/^ib(\d+)-(\d)/)
      {
        $ibTxKB[$i]=$fieldsNow[12]/256;
        $ibTx[$i]=  $fieldsNow[14];
        $ibRxKB[$i]=$fieldsNow[13]/256;
        $ibRx[$i]=  $fieldsNow[15];
      }
      else
      {
        $ibTxKB[$i]=$fields[12]/256;
        $ibTx[$i]=  $fields[14];
        $ibRxKB[$i]=$fields[13]/256;
        $ibRx[$i]=  $fields[15];
      }

      $ibTxKBTot+=$ibTxKB[$i];
      $ibTxTot+=  $ibTx[$i];
      $ibRxKBTot+=$ibRxKB[$i];
      $ibRxTot+=  $ibRx[$i];
      $ibErrorsTotTot+=$ibErrorsTot[$i];
    }
  }

  #    S L A B S

  # Note the trailing '$'.  This is because there is a Slab: in /proc/meminfo
  # Also note this handles both slab and slub
  elsif ($subsys=~/y/i && $type=~/^Slab$/)
  {
    # First comes /proc/slabinfo
    # this is a little complicated, but not too much as the order of the ||
    # is key.  The idea is that only in playback mode and then only if the
    # user specifies a list of slabs to look at do we ever execute
    # that ugly 'defined()' function.
    if ($slabinfoFlag &&
	 ($playback eq '' || $slabopts eq '' ||
	    defined($slabProc{(split(/ /,$data))[0]})))
    {
      # make sure we note this this interval has process data in it and is ready
      # to be reported.
      $interval2Print=1;

      # in case slabs don't always appear in same order (new ones
      # dynamically added?), we'll index everything...
      $name=(split(/ /, $data))[0];
      $slabIndex{$name}=$slabIndexNext++    if !defined($slabIndex{$name});
      $i=$slabIndex{$name};
      $slabName[$i]=$name;

      # very rare (I hope), but if the number of slabs grew after we started, make
      # a note in message log and init the variable that got missed because of this.
      if ($i>=$NumSlabs)
      {
        $NumSlabs++;
        $slabObjActLast[$i]=$slabObjAllLast[$i]=0;
        $slabSlabActLast[$i]=$slabSlabAllLast[$i]=0;
        logmsg("W", "New slab created after logging started")    
      }

      # since these are NOT counters, the values are actually totals from which we
      # can derive changes from individual entries.
      if ($SlabVersion eq '1.1')
      {
        ($slabObjActTot[$i], $slabObjAllTot[$i], $slabObjSize[$i],
         $slabSlabActTot[$i], $slabSlabAllTot[$i], $slabPagesPerSlab[$i])=(split(/\s+/, $data))[1..6];
      }
      elsif ($SlabVersion=~/^2/)
      {
        ($slabObjActTot[$i], $slabObjAllTot[$i], $slabObjSize[$i], 
         $slanObjPerSlab[$i], $slabPagesPerSlab[$i],
         $slabSlabActTot[$i], $slabSlabAllTot[$i])=(split(/\s+/, $data))[1..5,13,14];
      }

      # Total Sizes of objects and slabs
      $slabObjActTotB[$i]=$slabObjActTot[$i]*$slabObjSize[$i];
      $slabObjAllTotB[$i]=$slabObjAllTot[$i]*$slabObjSize[$i];
      $slabSlabActTotB[$i]=$slabSlabActTot[$i]*$slabPagesPerSlab[$i]*$PageSize;
      $slabSlabAllTotB[$i]=$slabSlabAllTot[$i]*$slabPagesPerSlab[$i]*$PageSize;

      $slabObjAct[$i]= $slabObjActTot[$i]- $slabObjActLast[$i];
      $slabObjAll[$i]= $slabObjAllTot[$i]- $slabObjAllLast[$i];
      $slabSlabAct[$i]=$slabSlabActTot[$i]-$slabSlabActLast[$i];
      $slabSlabAll[$i]=$slabSlabAllTot[$i]-$slabSlabAllLast[$i];

      $slabObjActLast[$i]= $slabObjActTot[$i];
      $slabObjAllLast[$i]= $slabObjAllTot[$i];
      $slabSlabActLast[$i]=$slabSlabActTot[$i];
      $slabSlabAllLast[$i]=$slabSlabAllTot[$i];

      # if -oS, only count slabs whose objects or sizes have changed
      # since last interval.
      # note -- this is only if !S and the slabs themselves change
      if ($options!~/S/ || $slabSlabAct[$i]!=0 || $slabSlabAll[$i]!=0)
      {
        $slabObjActTotal+=  $slabObjActTot[$i];
        $slabObjAllTotal+=  $slabObjAllTot[$i];
        $slabObjActTotalB+= $slabObjActTot[$i]*$slabObjSize[$i];
        $slabObjAllTotalB+= $slabObjAllTot[$i]*$slabObjSize[$i];
        $slabSlabActTotal+= $slabSlabActTot[$i];
        $slabSlabAllTotal+= $slabSlabAllTot[$i];
        $slabSlabActTotalB+=$slabSlabActTot[$i]*$slabPagesPerSlab[$i]*$PageSize;
        $slabSlabAllTotalB+=$slabSlabAllTot[$i]*$slabPagesPerSlab[$i]*$PageSize;
        $slabNumAct++       if $slabSlabAllTot[$i];
        $slabNumTot++;
      }
    }
    else
    {
      # Note as efficient as if..then..elsif..elsif... but a lot more readable
      # and more important, no appreciable difference in processing time
      my ($slabname, $datatype, $value)=split(/\s+/, $data);

      $slabdata{$slabname}->{objsize}=$value     if $datatype=~/^object_/;    # object_size
      $slabdata{$slabname}->{slabsize}=$value    if $datatype=~/^slab_/;      # slab_size  
      $slabdata{$slabname}->{order}=$value       if $datatype=~/^or/;         # order
      $slabdata{$slabname}->{objper}=$value      if $datatype=~/^objs/;       # objs_per_slab
      $slabdata{$slabname}->{objects}=$value     if $datatype=~/^objects/;

      # This is the second of the ('objects','slabs') tuple
      if ($datatype=~/^slabs/)
      { 
        my $numSlabs=$slabdata{$slabname}->{slabs}=$value;

        $interval2Print=1;
        $slabdata{$slabname}->{avail}=$slabdata{$slabname}->{objper}*$numSlabs;

	$slabNumTot+=     $numSlabs;
        $slabObjAvailTot+=$slabdata{$slabname}->{objper}*$numSlabs;
        $slabNumObjTot+=  $slabdata{$slabname}->{objects};
        $slabUsedTot+=    $slabdata{$slabname}->{used}=$slabdata{$slabname}->{slabsize}*$slabdata{$slabname}->{objects};
        $slabTotalTot+=   $slabdata{$slabname}->{total}=$value*($PageSize<<$slabdata{$slabname}->{order});
      }
    }
  }

  elsif ($subsys=~/Z/ && $type=~/^proc(T*):(\d+)/)
  {
    # Note that if 'T' appended, this is a thread.
    $threadFlag=($1 eq 'T') ? 1 : 0;
    $procPidNow=$2;

    # make sure we note this this interval has process data in it and is ready
    # to be reported.
    $interval2Print=1;

    # Whenever we see a new pid, we need to add to allocate a new index
    # and add it to the hash of indexes PLUS this is where we have to 
    # initialize the 'last' variables.
    if (!defined($procIndexes{$procPidNow}))
    {
      $i=$procIndexes{$procPidNow}=nextAvailProcIndex();
      $procMinFltLast[$i]=$procMajFltLast[$i]=0;
      $procUTimeLast[$i]=$procSTimeLast[$i]=$procCUTimeLast[$i]=$procCSTimeLast[$i]=0;
      $procRCharLast[$i]=$procWCharLast[$i]=$procSyscrLast[$i]=	$procSyscwLast[$i]=0;
      $procRBytesLast[$i]=$procWBytesLast[$i]=$procCancelLast[$i]=0;
      print "### new index $i allocated for $procPidNow\n"    if $debug & 256;
    }

    # note - %procSeen works just like %pidSeen, except to keep collection
    # and formatting separate, we need to keep these flags separate too,
    # expecially since in playback mode %pidSeen never gets set.
    $procSeen{$procPidNow}=1;
    $i=$procIndexes{$procPidNow};

    # Since the counters presented here are zero based, they're actually
    # the totalled already and all we need to is calculate the intervals
    if ($data=~/^stat/)
    {
      # 'C' variables include the values for dead children
      # Note that incomplete records happen too often to bother logging
      $procPid[$i]=$procPidNow;  # don't need to pull out of string...
      $procThread[$i]=$threadFlag;
      ($procName[$i], $procState[$i], $procPpid[$i], 
       $procMinFltTot[$i], $procMajFltTot[$i], 
       $procUTimeTot[$i], $procSTimeTot[$i], 
       $procCUTimeTot[$i], $procCSTimeTot[$i], $procPri[$i], $procNice[$i])=
		(split(/ /, $data))[2,3,4,10,12,14,15,16,17,18,19];
      return    if !defined($procSTimeTot[$i]);  # check for incomplete

      $procName[$i]=~s/[()]//g;  # proc names are wrapped in ()s
      $procPri[$i]="RT"    if $procPri[$i]<0;
      $procMinFlt[$i]=fix($procMinFltTot[$i]-$procMinFltLast[$i]);
      $procMajFlt[$i]=fix($procMajFltTot[$i]-$procMajFltLast[$i]);
      $procUTime[$i]= fix($procUTimeTot[$i]-$procUTimeLast[$i]);
      $procSTime[$i]= fix($procSTimeTot[$i]-$procSTimeLast[$i]);

      $procMinFltLast[$i]=$procMinFltTot[$i];
      $procMajFltLast[$i]=$procMajFltTot[$i];
      $procUTimeLast[$i]= $procUTimeTot[$i];
      $procSTimeLast[$i]= $procSTimeTot[$i];
    }

    # Handle the IO counters
    elsif ($data=~/^io (.*)/)
    {
      $data2=$1;

      # This might be easier to do in 7 separate 'if' blocks but
      # this keeps the code denser and may be easier to follow
      $procRChar=$1     if $data2=~/^rchar: (\d+)/;
      $procWChar=$1     if $data2=~/^wchar: (\d+)/;
      $procSyscr=$1     if $data2=~/^syscr: (\d+)/;
      $procSyscw=$1     if $data2=~/^syscw: (\d+)/;
      $procRBytes=$1    if $data2=~/^read_bytes: (\d+)/;
      $procWBytes=$1    if $data2=~/^write_bytes: (\d+)/;

      if ($data2=~/^cancelled_write_bytes: (\d+)/)
      {
        $procCancel=$1;
	$procRKBC[$i]=fix($procRChar-$procRCharLast[$i])/1024;
  	$procWKBC[$i]=fix($procWChar-$procWCharLast[$i])/1024;
	$procRSys[$i]=fix($procSyscr-$procSyscrLast[$i]);
	$procWSys[$i]=fix($procSyscw-$procSyscwLast[$i]);
	$procRKB[$i]= fix($procRBytes-$procRBytesLast[$i])/1024;
	$procWKB[$i]= fix($procWBytes-$procWBytesLast[$i])/1024;
	$procCKB[$i]= fix($procCancel-$procCancelLast[$i])/1024;

	$procRCharLast[$i]=$procRChar;
	$procWCharLast[$i]=$procWChar;
	$procSyscrLast[$i]=$procSyscr;
	$procSyscwLast[$i]=$procSyscw;
	$procRBytesLast[$i]=$procRBytes;
	$procWBytesLast[$i]=$procWBytes;
        $procCancelLast[$i]=$procCancel;
      }
    }

    # if bad stat file skip the rest
    elsif (!defined($procSTimeTot[$i])) { }
    elsif ($data=~/^cmd (.*)/)          { $procCmd[$i]=$1; }
    elsif ($data=~/^VmSize:\s+(\d+)/)   { $procVmSize[$i]=$1; }
    elsif ($data=~/^VmLck:\s+(\d+)/)    { $procVmLck[$i]=$1; }
    elsif ($data=~/^VmRSS:\s+(\d+)/)    { $procVmRSS[$i]=$1; }
    elsif ($data=~/^VmData:\s+(\d+)/)   { $procVmData[$i]=$1; }
    elsif ($data=~/^VmStk:\s+(\d+)/)    { $procVmStk[$i]=$1; }
    elsif ($data=~/^VmExe:\s+(\d+)/)    { $procVmExe[$i]=$1; }
    elsif ($data=~/^VmLib:\s+(\d+)/)    { $procVmLib[$i]=$1; }
    elsif ($data=~/^Uid:\s+(\d+)/)
    { 
      $uid=$1;
      $procUser[$i]=($playback eq '' || $passwdFile ne '') ? $UidSelector{$uid} : $uid;
      $procUser[$i]="???"    if !defined($procUser[$i]);
    }
  }
}

# headers for plot formatted data
sub printHeaders
{
  my $i;
  return    if $options=~/H/;

  ##############################
  #    Core Plot Format Headers
  ##############################

  $headersAll='';
  $datetime=(!$utcFlag) ? "#Date${SEP}Time${SEP}" : "#UTC${SEP}";
  $headers=($filename ne '') ? "$commonHeader$datetime" : $datetime;

  if ($subsys=~/c/)
  {
    $headers.="[CPU]User%${SEP}[CPU]Nice%${SEP}[CPU]Sys%${SEP}[CPU]Wait%${SEP}";
    $headers.="[CPU]Irq%${SEP}[CPU]Soft%${SEP}[CPU]Steal%${SEP}[CPU]Idle%${SEP}[CPU]Totl%${SEP}";
    $headers.="[CPU]Intrpt$rate${SEP}[CPU]Ctx$rate${SEP}[CPU]Proc$rate${SEP}";
    $headers.="[CPU]ProcQue${SEP}[CPU]ProcRun${SEP}[CPU]L-Avg1${SEP}[CPU]L-Avg5${SEP}[CPU]L-Avg15${SEP}"
  }

  if ($subsys=~/m/)
  {
    $headers.="[MEM]Tot${SEP}[MEM]Used${SEP}[MEM]Free${SEP}[MEM]Shared${SEP}[MEM]Buf${SEP}[MEM]Cached${SEP}";
    $headers.="[MEM]Slab${SEP}[MEM]Map${SEP}[MEM]Commit${SEP}";    # always from V1.7.5 forward
    $headers.="[MEM]SwapTot${SEP}[MEM]SwapUsed${SEP}[MEM]SwapFree${SEP}";
    $headers.="[MEM]Dirty${SEP}[MEM]Clean${SEP}[MEM]Laundry${SEP}[MEM]Inactive${SEP}[MEM]PageIn${SEP}[MEM]PageOut${SEP}";
  }

  if ($subsys=~/s/)
  {
    $headers.="[SOCK]Used${SEP}[SOCK]Tcp${SEP}[SOCK]Orph${SEP}[SOCK]Tw${SEP}[SOCK]Alloc${SEP}";
    $headers.="[SOCK]Mem${SEP}[SOCK]Udp${SEP}[SOCK]Raw${SEP}[SOCK]Frag${SEP}[SOCK]FragMem${SEP}";
  }

  if ($subsys=~/n/)
  {
    $headers.="[NET]RxPktTot${SEP}[NET]TxPktTot${SEP}[NET]RxKBTot${SEP}[NET]TxKBTot${SEP}";
    $headers.="[NET]RxCmpTot${SEP}[NET]RxMltTot${SEP}[NET]TxCmpTot${SEP}";
    $headers.="[NET]RxErrsTot${SEP}[NET]TxErrsTot${SEP}";
  }

  if ($subsys=~/d/)
  {
    $headers.="[DSK]ReadTot${SEP}[DSK]WriteTot${SEP}[DSK]OpsTot${SEP}";
    $headers.="[DSK]ReadKBTot${SEP}[DSK]WriteKBTot${SEP}[DSK]KbTot${SEP}";
    $headers.="[DSK]ReadMrgTot${SEP}[DSK]WriteMrgTot${SEP}[DSK]MrgTot${SEP}";
  }

  if ($subsys=~/i/)
  {
    $headers.="[INODE]dentry-unused${SEP}[INODE]openFiles${SEP}[INODE]%Max${SEP}[INODE]used${SEP}";
    $headers.="[INODE]super-used${SEP}[INODE]%Max${SEP}[INODE]dqout-used${SEP}[INODE]%Max${SEP}";
  }

  if ($subsys=~/f/)
  {
    my $nfsType=($subOpts=~/2/) ?  'NFS2' : 'NFS3';
    $nfsType.=  ($subOpts=~/C/) ?     'C' : 'S';
    $headers.="[NFS]Packets${SEP}[NFS]Udp${SEP}[NFS]Tcp${SEP}[NFS]TcpConn${SEP}[NFS]Calls${SEP}";
    $headers.=($subOpts!~/C/) ? "[NFS]BadAuth${SEP}[NFS]BadClient${SEP}" : "[NFS]Retrans${SEP}[NFS]AuthRef${SEP}";
    $headers.="[$nfsType]Reads${SEP}[$nfsType]Writes${SEP}";
  }

  if ($subsys=~/l/)
  {
    if ($reportMdsFlag)
    {
      $headers.="[MDS]Close${SEP}[MDS]Getattr${SEP}[MDS]Reint${SEP}[MDS]Sync${SEP}";
    }

    if ($reportOstFlag)
    {
      # We always report basic I/O independent of what user selects with -O
      $headers.="[OST]Read${SEP}[OST]ReadKB${SEP}[OST]Write${SEP}[OST]WriteKB${SEP}";
      if ($subOpts=~/B/)
      {
        foreach my $i (@brwBuckets)
        { $headers.="[OSTB]r${i}P${SEP}"; }
        foreach my $i (@brwBuckets)
        { $headers.="[OSTB]w${i}P${SEP}"; }
      }
    }
    if ($subOpts=~/D/)
    {
      $headers.="[OSTD]Rds${SEP}[OSTD]Rdk${SEP}[OSTD]Wrts${SEP}[OSTD]Wrtk${SEP}";
      foreach my $i (@diskBuckets)
      { $headers.="[OSTD]r${i}K${SEP}"; }
      foreach my $i (@diskBuckets)
      { $headers.="[OSTD]w${i}K${SEP}"; }
    }

    if ($reportCltFlag)
    {
      # 4 different sizes based on whether or not -OB, -OM and/or -OR selected.
      # NOTE - order IS critical
      $headers.="[CLT]Reads${SEP}[CLT]ReadKB${SEP}[CLT]Writes${SEP}[CLT]WriteKB${SEP}";
      $headers.="[CLTM]Open${SEP}[CLTM]Close${SEP}[CLTM]GAttr${SEP}[CLTM]SAttr${SEP}[CLTM]Seek${SEP}[CLTM]FSync${SEP}[CLTM]DrtHit${SEP}[CLTM]DrtMis${SEP}"
		    if $subOpts=~/M/;
      $headers.="[CLTR]Pend${SEP}[CLTR]Hits${SEP}[CLTR]Misses${SEP}[CLTR]NotCon${SEP}[CLTR]MisWin${SEP}[CLTR]LckFal${SEP}[CLTR]Discrd${SEP}[CLTR]ZFile${SEP}[CLTR]ZerWin${SEP}[CLTR]RA2Eof${SEP}[CLTR]HitMax${SEP}"
		    if $subOpts=~/R/;
      if ($subOpts=~/B/)
      {
        foreach my $i (@brwBuckets)
        { $headers.="[CLTB]r${i}P${SEP}"; }
        foreach my $i (@brwBuckets)
        { $headers.="[CLTB]w${i}P${SEP}"; }
      }
    }
  }

  if ($subsys=~/x/)
  {
    my $int=($NumXRails) ? 'ELAN' : 'IB';
    $headers.="[$int]InPkt${SEP}[$int]OutPkt${SEP}[$int]InKB${SEP}[$int]OutKB${SEP}[$int]Err${SEP}";
  }

  if ($subsys=~/t/)
  {
    $headers.="[TCP]PureAcks${SEP}[TCP]HPAcks${SEP}[TCP]Loss${SEP}[TCP]FTrans${SEP}";
  }

  if ($subsys=~/y/)
  {
    $headers.="[SLAB]ObjInUse${SEP}[SLAB]ObjInUseB${SEP}[SLAB]ObjAll${SEP}[SLAB]ObjAllB${SEP}";
    $headers.="[SLAB]InUse${SEP}[SLAB]InUseB${SEP}[SLAB]All${SEP}[SLAB]AllB${SEP}[SLAB]CacheInUse${SEP}[SLAB]CacheTotal${SEP}";
  }

  # only if at least one core subsystem selected.  if not, make sure
  # $headersAll contains the date/time in case writing to the terminal
  writeData(0, '', \$headers, $LOG, $ZLOG, 'log', \$headersAll)    if $coreFlag;
  $headersAll=$headers    if !$coreFlag;

  #################################
  #    Non-Core Plot Format Headers
  #################################

  # here's the deal with these.  if writing to files, each file always gets
  # their own headers.  However, if writing to the terminal we want one long
  # string begining with a single date/time AND we don't bother with the 
  # common header.

  $cpuHeaders=$dskHeaders=$envHeaders=$nfsHeaders=$netHeaders='';
  $ostHeaders=$mdsHeaders=$cltHeaders=$tcpHeaders=$elanHeaders='';

  # Whenever we print a header to a file, we do both the common header
  # and date/time.  Remember, if we're printing the terminal, this is
  # completely ignored by writeData().
  $ch=($filename ne '') ? "$commonHeader$datetime" : $datetime;

  if ($subsys=~/C/)
  { 
    for ($i=0; $i<$NumCpus; $i++)
    {
      $cpuHeaders.="[CPU:$i]User%${SEP}[CPU:$i]Nice%${SEP}[CPU:$i]Sys%${SEP}";
      $cpuHeaders.="[CPU:$i]Wait%${SEP}[CPU:$i]Irq%${SEP}[CPU:$i]Soft%${SEP}";
      $cpuHeaders.="[CPU:$i]Steal%${SEP}[CPU:$i]Idle%${SEP}[CPU:$i]Totl%${SEP}";
    }
    writeData(0, $ch, \$cpuHeaders, CPU, $ZCPU, 'cpu', \$headersAll);
  }

  if ($subsys=~/D/ && $options!~/x/)
  {
    for ($i=0; $i<$NumDisks; $i++)
    {
      $temp= "[DSK]Name${SEP}[DSK]Reads${SEP}[DSK]RMerge${SEP}[DSK]RKBytes${SEP}";
      $temp.="[DSK]Writes${SEP}[DSK]WMerge${SEP}[DSK]WKBytes${SEP}[DSK]Request${SEP}";
      $temp.="[DSK]QueLen${SEP}[DSK]Wait${SEP}[DSK]SvcTim${SEP}[DSK]Util${SEP}";
      $temp=~s/DSK/DSK:$dskName[$i]/g;
      $temp=~s/cciss\///g;
      $dskHeaders.=$temp;
    }
    writeData(0, $ch, \$dskHeaders, DSK, $ZDSK, 'dsk', \$headersAll);
  }

  if ($subsys=~/E/)
  {
    for ($i=1; $i<=$NumFans; $i++)
    {
      $envHeaders.="[FAN$i]${SEP}";
    }
    for ($i=1; $i<=$NumPwrs; $i++)
    {
      $envHeaders.="[PWR$i]${SEP}";
    }
    for ($i=1; $i<=$NumTemps; $i++)
    {
      $envHeaders.="[TEMP$i]${SEP}";
    }
    writeData(0, $ch, \$envHeaders, ENV, $ZENV, 'env', \$headersAll);
  }

  if ($subsys=~/F/)
  {
     if ($subOpts=~/2/)
    {
      my $type=($subOpts=~/C/) ? 'NFS2CD' : 'NFS2SD';
      $nfsHeaders.="[$type]Null${SEP}[$type]Getattr${SEP}[$type]Setattr${SEP}[$type]Root${SEP}[$type]Lookup${SEP}[$type]Readlink${SEP}";
      $nfsHeaders.="[$type]Read${SEP}[$type]Wrcache${SEP}[$type]Write${SEP}[$type]Create${SEP}[$type]Remove${SEP}[$type]Rename${SEP}";
      $nfsHeaders.="[$type]Link${SEP}[$type]Symlink${SEP}[$type]Mkdir${SEP}[$type]Rmdir${SEP}[$type]Readdir${SEP}[$type]Fsstat${SEP}";
    }

    if ($subOpts=~/3/)
    {
      my $type=($subOpts=~/C/) ? 'NFS3CD' : 'NFS3SD';
      $nfsHeaders.="[$type]Null${SEP}[$type]Getattr${SEP}[$type]Setattr${SEP}[$type]Lookup${SEP}[$type]Access${SEP}[$type]Readlink${SEP}";
      $nfsHeaders.="[$type]Read${SEP}[$type]Write${SEP}[$type]Create${SEP}[$type]Mkdir${SEP}[$type]Symlink${SEP}[$type]Mknod${SEP}";
      $nfsHeaders.="[$type]Remove${SEP}[$type]Rmdir${SEP}[$type]Rename${SEP}[$type]Link${SEP}[$type]Readdir${SEP}";
      $nfsHeaders.="[$type]Readdirplus${SEP}[$type]Fsstat${SEP}[$type]Fsinfo${SEP}[$type]Pathconf${SEP}[$type]Commit${SEP}";
    }
    writeData(0, $ch, \$nfsHeaders, NFS, $ZNFS, 'nfs', \$headersAll);
   }

  if ($subsys=~/N/)
  {
    for ($i=0; $i<$NumNets; $i++)
    {
      $temp= "[NET]Name${SEP}[NET]RxPkt${SEP}[NET]TxPkt${SEP}[NET]RxKB${SEP}[NET]TxKB${SEP}";
      $temp.="[NET]RxErr${SEP}[NET]RxDrp${SEP}[NET]RxFifo${SEP}[NET]RxFra${SEP}[NET]RxCmp${SEP}[NET]RxMlt${SEP}";
      $temp.="[NET]TxErr${SEP}[NET]TxDrp${SEP}[NET]TxFifo${SEP}[NET]TxColl${SEP}[NET]TxCar${SEP}";
      $temp.="[NET]TxCmp${SEP}[NET]RxErrs${SEP}[NET]TxErrs${SEP}";
      $temp=~s/NET/NET:$netName[$i]/g;
      $temp=~s/:]/]/g;
      $netHeaders.=$temp;
    }
    writeData(0, $ch, \$netHeaders, NET, $ZNET, 'net', \$headersAll);
  }

  if ($subsys=~/L/)
  {
    if ($reportOstFlag)
    {
      # We always start with this section
      # BRW stats are optional, but if there group them together separately.

      for ($i=0; $i<$NumOst; $i++)
      { 
        $inst=$lustreOsts[$i];
        $ostHeaders.="[OST:$inst]Ost${SEP}[OST:$inst]Read${SEP}[OST:$inst]ReadKB${SEP}[OST:$inst]Write${SEP}[OST:$inst]WriteKB${SEP}";
      }

      for ($i=0; $subOpts=~/B/ && $i<$NumOst; $i++)
      { 
        $inst=$lustreOsts[$i];
        foreach my $j (@brwBuckets)
        { $ostHeaders.="[OSTB:$inst]r$j${SEP}"; }
        foreach my $j (@brwBuckets)
        { $ostHeaders.="[OSTB:$inst]w$j${SEP}"; }
      }
      writeData(0, $ch, \$ostHeaders, OST, $ZOST, 'ost', \$headersAll);
    }

    if ($reportCltFlag)
    {
      $temp='';
      if ($subsys=~/LL/)  # client OST details
      {
	# we always record I/O in one chunk
	for ($i=0; $i<$NumLustreCltOsts; $i++)
        {
          $inst=$lustreCltOsts[$i];
          $temp.="[CLT:$inst]FileSys${SEP}[CLT:$inst]Ost${SEP}[CLT:$inst]Reads${SEP}[CLT:$inst]ReadKB${SEP}[CLT:$inst]Writes${SEP}[CLT:$inst]WriteKB${SEP}";
        }

	# and if specified, brw stats follow
        if ($subOpts=~/B/)
        {
  	  for ($i=0; $i<$NumLustreCltOsts; $i++)
          {
            $inst=$lustreCltOsts[$i];
            foreach my $j (@brwBuckets)
            { $temp.="[CLTB:$inst]r${j}P${SEP}"; }
            foreach my $j (@brwBuckets)
            { $temp.="[CLTB:$inst]w${j}P${SEP}"; }
	  }
	}
      }
      else  # just fs details
      {
	# just like with LL, these three follow each other in groups
	for ($i=0; $i<$NumLustreFS; $i++)
        {
          $inst=$lustreCltFS[$i];
          $temp.="[CLT:$inst]FileSys${SEP}[CLT:$inst]Reads${SEP}[CLT:$inst]ReadKB${SEP}[CLT:$inst]Writes${SEP}[CLT:$inst]WriteKB${SEP}";
        }
	for ($i=0; $subOpts=~/M/ && $i<$NumLustreFS; $i++)
        {
          $inst=$lustreCltFS[$i];
	  $temp.="[CLTM:$inst]Open${SEP}[CLTM:$inst]Close${SEP}[CLTM:$inst]GAttr${SEP}[CLTM:$inst]SAttr${SEP}";
          $temp.="[CLTM:$inst]Seek${SEP}[CLTM:$inst]Fsync${SEP}[CLTM:$inst]DrtHit${SEP}[CLTM:$inst]DrtMis${SEP}";
        }
        for ($i=0; $subOpts=~/R/ && $i<$NumLustreFS; $i++)
        {
          $inst=$lustreCltFS[$i];
          $temp.="[CLTR:$inst]Pend${SEP}[CLTR:$inst]Hits${SEP}[CLTR:$inst]Misses${SEP}[CLTR:$inst]NotCon${SEP}[CLTR:$inst]MisWin${SEP}[CLTR:$inst]LckFal${SEP}";
          $temp.="[CLTR:$inst]Discrd${SEP}[CLTR:$inst]ZFile${SEP}[CLTR:$inst]ZerWin${SEP}[CLTR:$inst]RA2Eof${SEP}[CLTR:$inst]HitMax${SEP}";
	}
      }
      $cltHeaders.=$temp;
      writeData(0, $ch, \$cltHeaders, CLT, $ZCLT, 'clt', \$headersAll);
    }

    if ($subOpts=~/D/)
    {
      $rdHeader="[OSTD]rds${SEP}[OSTD]rdkb${SEP}";
      $wrHeader="[OSTD]wrs${SEP}[OSTD]wrkb${SEP}";
      foreach my $i (@diskBuckets)
      { $rdHeader.="[OSTD]r${i}K${SEP}"; }
      foreach my $i (@diskBuckets)
      { $wrHeader.="[OSTD]w${i}K${SEP}"; }

      for ($i=0; $i<$NumLusDisks; $i++)
      {
        $temp="[OSTD]Disk${SEP}$rdHeader${SEP}$wrHeader";
        $temp=~s/OSTD/OSTD:$LusDiskNames[$i]/g;
	$blkHeaders.="$temp${SEP}";
      }
      writeData(0, $ch, \$blkHeaders, BLK, $ZBLK, 'blk', \$headersAll);
    }
  }

  if ($subsys=~/T/)
  { 
    $tcpHeaders.="[TCPD]SyncookiesSent${SEP}[TCPD]SyncookiesRecv${SEP}[TCPD]SyncookiesFailed${SEP}[TCPD]EmbryonicRsts${SEP}";
    $tcpHeaders.="[TCPD]PruneCalled${SEP}[TCPD]RcvPruned${SEP}[TCPD]OfoPruned${SEP}[TCPD]OutOfWindowIcmps${SEP}[TCPD]LockDroppedIcmps${SEP}";
    $tcpHeaders.="[TCPD]ArpFilter${SEP}[TCPD]TW${SEP}[TCPD]TWRecycled${SEP}[TCPD]TWKilled${SEP}[TCPD]PAWSPassive${SEP}[TCPD]PAWSActive${SEP}";
    $tcpHeaders.="[TCPD]PAWSEstab${SEP}[TCPD]DelayedACKs${SEP}[TCPD]DelayedACKLocked${SEP}[TCPD]DelayedACKLost${SEP}";
    $tcpHeaders.="[TCPD]ListenOverflows${SEP}[TCPD]ListenDrops${SEP}[TCPD]Prequeued${SEP}[TCPD]DirectCopyFromBacklog${SEP}";
    $tcpHeaders.="[TCPD]DirectCopyFromPrequeue${SEP}[TCPD]PrequeueDropped${SEP}[TCPD]HPHits${SEP}[TCPD]HPHitsToUser${SEP}";
    $tcpHeaders.="[TCPD]PureAcks${SEP}[TCPD]HPAcks${SEP}[TCPD]RenoRecovery${SEP}[TCPD]SackRecovery${SEP}[TCPD]TACKReneging${SEP}";
    $tcpHeaders.="[TCPD]FACKReorder${SEP}[TCPD]SACKReorder${SEP}[TCPD]RenoReorder${SEP}[TCPD]TSReorder${SEP}[TCPD]FullUndo${SEP}";
    $tcpHeaders.="[TCPD]PartialUndo${SEP}[TCPD]DSACKUndo${SEP}[TCPD]LossUndo${SEP}[TCPD]Loss${SEP}[TCPD]LostRetransmit${SEP}";
    $tcpHeaders.="[TCPD]RenoFailures${SEP}[TCPD]SackFailures${SEP}[TCPD]LossFailures${SEP}[TCPD]FastRetrans${SEP}[TCPD]ForwardRetrans${SEP}";
    $tcpHeaders.="[TCPD]SlowStartRetrans${SEP}[TCPD]Timeouts${SEP}[TCPD]RenoRecoveryFail${SEP}[TCPD]SackRecoveryFail${SEP}";
    $tcpHeaders.="[TCPD]SchedulerFailed${SEP}[TCPD]RcvCollapsed${SEP}[TCPD]DSACKOldSent${SEP}[TCPD]DSACKOfoSent${SEP}";
    $tcpHeaders.="[TCPD]DSACKRecv${SEP}[TCPD]DSACKOfoRecv${SEP}[TCPD]AbortOnSyn${SEP}[TCPD]AbortOnData${SEP}[TCPD]AbortOnClose${SEP}";
    $tcpHeaders.="[TCPD]AbortOnMemory${SEP}[TCPD]AbortOnTimeout${SEP}[TCPD]AbortOnLinger${SEP}[TCPD]AbortFailed${SEP}";
    $tcpHeaders.="[TCPD]MemoryPressures${SEP}";

    writeData(0, $ch, \$tcpHeaders, TCP, $ZTCP, 'tcp', \$headersAll);
  }

  if ($subsys=~/X/ && $NumXRails)
  {
    for ($i=0; $i<$NumXRails; $i++)
    {
      $elanHeaders.="[ELAN:$i]Rail${SEP}[ELAN:$i]Rx${SEP}[ELAN:$i]Tx${SEP}[ELAN:$i]RxKB${SEP}[ELAN:$i]TxKB${SEP}[ELAN:$i]Get${SEP}[ELAN:$i]Put${SEP}[ELAN:$i]GetKB${SEP}[ELAN:$i]PutKB${SEP}[ELAN:$i]Comp${SEP}[ELAN:$i]CompKB${SEP}[ELAN:$i]SendFail${SEP}[ELAN:$i]Atomic${SEP}[ELAN:$i]DMA${SEP}";
    }
    writeData(0, $ch, \$elanHeaders, ELN, $ZELN, 'eln', \$headersAll);
  }

  if ($subsys=~/X/ && $NumHCAs)
  {
    for ($i=0; $i<$NumHCAs; $i++)
    {
      $ibHeaders.="[IB:$i]HCA${SEP}[IB:$i]InPkt${SEP}[IB:$i]OutPkt${SEP}[IB:$i]InKB${SEP}[IB:$i]OutKB${SEP}[IB:$i]Err${SEP}";
    }
    writeData(0, $ch, \$ibHeaders, IB, $ZIB, 'ib', \$headersAll);
  }

  # When going to the terminal OR socket we need a final call with no 'data' 
  # to write.  Also note that there is a final separator that needs to be removed
  $headersAll=~s/$SEP$//;
  writeData(1, '', undef, $LOG, undef, undef, \$headersAll)
	    if !$logToFileFlag || $addrFlag;

  #################################
  #    Exception File Headers
  #################################

  if ($options=~/x/i)
  {
    if ($subsys=~/D/)
    {
      $dskHeaders="Num${SEP}";
      $dskHeaders.="[DISKX]Name${SEP}[DISKX]Reads${SEP}[DISKX]Merged${SEP}[DISKX]KBytes${SEP}[DISKX]Writes${SEP}[DISKX]Merged${SEP}";
      $dskHeaders.="[DISKX]KBytes${SEP}[DISKX]Request${SEP}[DISKX]QueLen${SEP}[DISKX]Wait${SEP}[DISKX]SvcTim${SEP}[DISKX]Util\n";

      # Since we never write exception data over a socket the last parameter is undef.
      writeData(0, $ch, \$dskHeaders, DSKX, $ZDSKX, 'dskx', undef);
    }
  }
  $headersPrinted=1;
}

sub intervalPrint
{
  my $seconds=shift;

  # If seconds end in .000, $seconds comes across as integer with no $usecs!
  ($seconds, $usecs)=split(/\./, $seconds);
  $usecs=0    if !defined($usecs);
  if ($hiResFlag)
  {
    $usecs=substr("${usecs}00", 0, 3);
    $seconds.=".$usecs";
  }
  $totalCounter++;
  derived();    # some variables are derived from others before printing

  printPlot($seconds, $usecs)     if  $plotFlag;
  printTerm($seconds, $usecs)     if !$plotFlag && !$sexprFlag;
  printSexprRaw()                 if  $sexprFlag==1;
  printSexprRate()                if  $sexprFlag==2;
}

# anything that needs to be derived should be done only once and this is the place
sub derived
{
  if ($kernel2_4)
  {
    # some systems (like IA64) defined inactive and not the other 3, so this will combine
    # them all...
    $inactive+=$dirty+$clean+$laundry;
  }
  else
  {
    $memUsed=$memTot-$memFree;
    $swapUsed=$swapTotal-$swapFree;
  }
}

###########################
#    P l o t    F o r m a t
###########################

sub printPlot
{
  my $seconds=shift;
  my $usecs=  shift;
  my ($datestamp, $time, $hh, $mm, $ss, $mday, $mon, $year, $i, $j);

  # We always print some form of date and time in plot format and in the case of
  # --utc, it's a single value.  Now that I'm pulling out usecs for utc we
  # probably don't have to pass it as the second parameter.
  $utcSecs=(split(/\./, $seconds))[0];
  ($ss, $mm, $hh, $mday, $mon, $year)=localtime($seconds);
  $date=($options=~/d/) ?
         sprintf("%02d/%02d", $mon+1, $mday) :
         sprintf("%d%02d%02d", $year+1900, $mon+1, $mday);
  $time= sprintf("%02d:%02d:%02d", $hh, $mm, $ss);
  my $datetime=(!$utcFlag) ? "$date$SEP$time": $utcSecs;
  $datetime.=".$usecs"    if $options=~/m/;

  # slab detail and processes have their own print routines because they
  # do multiple lines of output and can't be mixed with anything else.
  # Furthermore, if we're doing -rawtoo, we DON'T generate these files since
  # the data is already being recorded in the raw file and we don't want to do
  # both
  if (!$rawtooFlag && $subsys=~/[YZ]/ && $interval2Print && $interval2Counter>1)
  {
    printPlotSlab($date, $time)    if $subsys=~/Y/;
    printPlotProc($date, $time)    if $subsys=~/Z/;
    return    if $subsys=~/^[YZ]$/;    # we're done if ONLY printing slabs or processes
  }

  printHeaders()
        if !$headersPrinted ||
           ($options!~/h/ && $filename eq '' && ($totalCounter % $headerRepeat)==0);

  #######################
  #    C O R E    D A T A
  #######################

  $plot=$oneline='';
  if ($coreFlag)
  {
    # CPU Data cols
    if ($subsys=~/c/)
    {
      $i=$NumCpus;
      $plot.=sprintf("$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS",
                $userP[$i], $niceP[$i], $sysP[$i], $waitP[$i],
                $irqP[$i], $softP[$i], $stealP[$i], $idleP[$i], $totlP[$i]);
      $plot.=sprintf("$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%d$SEP%d",
                $intrpt/$intSecs, $ctxt/$intSecs, $proc/$intSecs,
                $loadQue, $loadRun, $loadAvg1, $loadAvg5, $loadAvg15);
    }

    # MEM
    if ($subsys=~/m/)
    {
      $plot.=sprintf("$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS",
                $memTot, $memUsed, $memFree, $memShared, $memBuf, $memCached); 
      $plot.=sprintf("$SEP%$FS$SEP%$FS$SEP%$FS", $memSlab, $memMap, $memCommit);   # Always from V1.7.5 forward
      $plot.=sprintf("$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS",
                $swapTotal, $swapUsed, $swapFree,
                $dirty, $clean, $laundry, $inactive,
                $pagein/$intSecs, $pageout/$intSecs);
    }

    # SOCKETS
    if ($subsys=~/s/)
    {
      $plot.="$SEP$sockUsed$SEP$sockTcp$SEP$sockOrphan$SEP$sockTw$SEP$sockAlloc";
      $plot.="$SEP$sockMem$SEP$sockUdp$SEP$sockRaw$SEP$sockFrag$SEP$sockFragM";
    }

    # NETWORKS
    if ($subsys=~/n/)
    {
      $plot.=sprintf("$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS",
                $netRxPktTot/$intSecs, $netTxPktTot/$intSecs,
                $netRxKBTot/$intSecs,  $netTxKBTot/$intSecs,
                $netRxCmpTot/$intSecs, $netRxMltTot/$intSecs,
                $netTxCmpTot/$intSecs, $netRxErrsTot/$intSecs,
                $netTxErrsTot/$intSecs);
    }

    # DISKS
    if ($subsys=~/d/)
    {
      $plot.=sprintf("$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS",
                $dskReadTot/$intSecs,    $dskWriteTot/$intSecs,    $dskOpsTot/$intSecs,
                $dskReadKBTot/$intSecs,  $dskWriteKBTot/$intSecs,  ($dskReadKBTot+$dskWriteKBTot)/$intSecs,
                $dskReadMrgTot/$intSecs, $dskWriteMrgTot/$intSecs, ($dskReadMrgTot+$dskWriteMrgTot)/$intSecs);
    }

    # INODES
    if ($subsys=~/i/)
    {
      $plot.=sprintf("$SEP%d$SEP%d$SEP%$FS$SEP%d$SEP%d$SEP%$FS$SEP%d$SEP%$FS",
        $unusedDCache, $openFiles, $OFMax ? $openFiles*100/$OFMax  : 0,
        $inodeUsed,    $superUsed, $SBMax ? $superUsed*100/$SBMax  : 0,
        $dquotUsed,                $DQMax ? $dquoteUsed*100/$DQMax : 0);
    }

    # NFS
    if ($subsys=~/f/)
    {
      $plot.=sprintf("$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS",
            $nfsPkts/$intSecs,    $nfsUdp/$intSecs,
            $nfsTcp/$intSecs,     $nfsTcpConn/$intSecs, $rpcCalls/$intSecs);

      $plot.=sprintf("$SEP%$FS$SEP%$FS", $rpcBadAuth/$intSecs, $rpcBadClnt/$intSecs)    if $subOpts!~/C/;
      $plot.=sprintf("$SEP%$FS$SEP%$FS", $rpcRetrans/$intSecs, $rpcCredRef/$intSecs)    if $subOpts=~/C/;

      $plot.=sprintf("$SEP%$FS$SEP%$FS", $nfs2Read/$intSecs, $nfs2Write/$intSecs)  if $subOpts=~/2/;
      $plot.=sprintf("$SEP%$FS$SEP%$FS", $nfsRead/$intSecs,  $nfsWrite/$intSecs)   if $subOpts=~/3/;
    }

    # Lustre
    if ($subsys=~/l/)
    {
      # MDS goes first since for detail, the OST is variable and if we ever
      # do both we want consistency of order
      $plot.=sprintf("$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS",
        $lustreMdsClose/$intSecs, $lustreMdsGetattr/$intSecs,
        $lustreMdsReint/$intSecs, $lustreMdsSync/$intSecs)
                    if $reportMdsFlag;

      if ($reportOstFlag)
      {
	# We always do this...
        $plot.=sprintf("$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS",
           $lustreReadOpsTot/$intSecs,  $lustreReadKBytesTot/$intSecs,
           $lustreWriteOpsTot/$intSecs, $lustreWriteKBytesTot/$intSecs);

        if ($subOpts=~/B/)
        {
          for ($j=0; $j<$numBrwBuckets; $j++)
          {
            $plot.=sprintf("$SEP%$FS", $lustreBufReadTot[$j]/$intSecs);
          }
          for ($j=0; $j<$numBrwBuckets; $j++)
          {
            $plot.=sprintf("$SEP%$FS", $lustreBufWriteTot[$j]/$intSecs);
          }
        }
      }

      # Disk Block Level Stats can apply to both MDS and OST
      if ($subOpts=~/D/)
      {
        $plot.=sprintf("$SEP%d$SEP%d$SEP%d$SEP%d",
	       $lusDiskReadsTot[$LusMaxIndex]/$intSecs, 
               $lusDiskReadBTot[$LusMaxIndex]*0.5/$intSecs,
	       $lusDiskWritesTot[$LusMaxIndex]/$intSecs, 
               $lusDiskWriteBTot[$LusMaxIndex]*0.5/$intSecs);
        for ($i=0; $i<$LusMaxIndex; $i++)
        { $plot.=sprintf("$SEP%d", $lusDiskReadsTot[$i]/$intSecs); }
        for ($i=0; $i<$LusMaxIndex; $i++)
        { $plot.=sprintf("$SEP%d", $lusDiskWritesTot[$i]/$intSecs); }
      }

      if ($reportCltFlag)
      {
	# There are actually 3 different formats depending on -O
	$plot.=sprintf("$SEP%d$SEP%d$SEP%d$SEP%d",
	    $lustreCltReadTot/$intSecs,      $lustreCltReadKBTot/$intSecs,
	    $lustreCltWriteTot/$intSecs,     $lustreCltWriteKBTot/$intSecs);
        $plot.=sprintf("$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d",
	    $lustreCltOpenTot/$intSecs,      $lustreCltCloseTot/$intSecs, 
	    $lustreCltGetattrTot/$intSecs,   $lustreCltSetattrTot/$intSecs, 
	    $lustreCltSeekTot/$intSecs,      $lustreCltFsyncTot/$intSecs,  
            $lustreCltDirtyHitsTot/$intSecs, $lustreCltDirtyMissTot/$intSecs)
		if $subOpts=~/M/;
        $plot.=sprintf("$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d",
            $lustreCltRAPendingTot,  $lustreCltRAHitsTot,    $lustreCltRAMissesTot,
            $lustreCltRANotConTot,   $lustreCltRAMisWinTot,  $lustreCltRALckFailTot,
            $lustreCltRAReadDiscTot, $lustreCltRAZeroLenTot, $lustreCltRAZeroWinTot,
            $lustreCltRA2EofTot,     $lustreCltRAHitMaxTot)
		if $subOpts=~/R/;

        if ($subOpts=~/B/) {
          for ($i=0; $i<$numBrwBuckets; $i++) {
            $plot.=sprintf("$SEP%d", $lustreCltRpcReadTot[$i]/$intSecs);
          }
          for ($i=0; $i<$numBrwBuckets; $i++) {
            $plot.=sprintf("$SEP%d", $lustreCltRpcWriteTot[$i]/$intSecs);
          }
        }
      }
    }

    #ELAN
    if ($subsys=~/x/ && $NumXRails)
    {
      $elanErrors=$elanSendFailTot+$elanNeterrAtomicTot+$elanNeterrDmaTot;
      $plot.=sprintf("$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS",
		$elanRxTot/$intSecs,   $elanTxTot/$intSecs,
		$elanRxKBTot/$intSecs, $elanTxKBTot/$intSecs,
		$elanErrors/$intSecs);
    }

    # INFINIBAND
    # Now if 'x' specified and neither ELAN or IB, we still want to print all 0s so lets
    # do it here (we could have done it in the ELAN routines is we wanted to).
    if ($subsys=~/x/ && ($NumHCAs || ($NumHCAs==0 && $NumXRails==0)))
    {
      $plot.=sprintf("$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS",
		$ibRxTot/$intSecs,   $ibTxTot/$intSecs,
		$ibRxKBTot/$intSecs, $ibTxKBTot/$intSecs,
                $ibErrorsTotTot);
    }

    # TCP
    if ($subsys=~/t/)
    {
      foreach $i (27, 28, 40, 45)
      {
	$plot.=sprintf("$SEP%$FS", $tcpValue[$i]/$intSecs);
      }
    }

    # SLAB
    if ($subsys=~/y/)
    {
      $plot.=sprintf("$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d",
	$slabObjActTotal,  $slabObjActTotalB,  $slabObjAllTotal,  $slabObjAllTotalB,
	$slabSlabActTotal, $slabSlabActTotalB, $slabSlabAllTotal, $slabSlabAllTotalB,
   	$slabNumAct,       $slabNumTot,6);
    }

    writeData(0, $datetime, \$plot, $LOG, $ZLOG, 'log', \$oneline);
  }

  ###############################
  #    N O N - C O R E    D A T A
  ###############################

  if ($subsys=~/C/)
  {
    $cpuPlot='';
    for ($i=0; $i<$NumCpus; $i++)
    {
      $cpuPlot.=sprintf("$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS",
                $userP[$i], $niceP[$i],  $sysP[$i],  $waitP[$i], $irqP[$i],  
                $softP[$i], $stealP[$i], $idleP[$i], $totlP[$i]);
    }
    writeData(0, $datetime, \$cpuPlot, CPU, $ZCPU, 'cpu', \$oneline);
  }

  #####################
  #    D S K    F i l e
  #####################

  if ($subsys=~/D/)
  {
    $dskPlot='';
    for ($i=0; $i<$NumDisks; $i++)
    {
      # We don't always need this but it sure makes it simpler this way
      # also note that the name isn't really plottable...
      $dskRecord=sprintf("%s$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS",
                $dskName[$i],
                $dskRead[$i]/$intSecs,    $dskReadMrg[$i]/$intSecs,  $dskReadKB[$i]/$intSecs,
                $dskWrite[$i]/$intSecs,   $dskWriteMrg[$i]/$intSecs, $dskWriteKB[$i]/$intSecs,
                $dskRqst[$i], $dskQueLen[$i], $dskWait[$i], $dskSvcTime[$i], $dskUtil[$i]);

      # If exception processing in effect and writing to a file, make sure this entry
      # qualities

      if ($options=~/x/i)
      {
        # All we care about for I/O rates is if one is greater than exception.
        $ios=$dskRead[$i]/$intSecs>=$limIOS || $dskWrite[$i]/$intSecs>=$limIOS;
        $svc=$dskSvcTime[$i]*100;

        # Either both tests are > limits or just one, depending on whether AND or OR
        writeData(0, $datetime, \$dskRecord, DSKX, $ZDSKX, 'dskx', undef)
	        if ($limBool && $ios && $svc>=$limSVC) || (!$limBool && ($ios || $svc>=$limSVC));
      }

      # If not doing x-exception reporting, just build one long string
      $dskPlot.="$SEP$dskRecord"    if $options!~/x/;
    }

    # we only write DSK data when NOT doing x type execption processing
    writeData(0, $datetime, \$dskPlot, DSK, $ZDSK, 'dsk', \$oneline)    if $options!~/x/;
  }

  ###############################
  #    E N V R I O N M E N T A L
  ###############################

  if ($subsys=~/E/)
  {
    $envPlot='';
    for ($i=1; $i<=$NumFans; $i++)
    {
      $envPlot.="$fanStat[$i]-$fanText[$i]$SEP";
    }
    for ($i=1; $i<=$NumPwrs; $i++)
    {
      $envPlot.="$pwrStat[$i]$SEP";
    }
    for ($i=1; $i<=$NumTemps; $i++)
    {
      $envPlot.="$tempTemp[$i]$SEP";
    }
    $envPlot=~s/ $//;
    writeData(0, $datetime, \$envPlot, ENV, $ZENV, 'env', \$oneline);
  }

  ##########################################
  #    L U S T R E    D E T A I L    F i l e
  ##########################################

  if ($subsys=~/L/)
  {
    if ($reportOstFlag)
    {
      # Basic I/O always there and grouped together
      $ostPlot='';
      for ($i=0; $i<$NumOst; $i++)
      {
        $ostPlot.=sprintf("$SEP%s$SEP%d$SEP%d$SEP%d$SEP%d",
	    $lustreOsts[$i],
            $lustreReadOps[$i]/$intSecs,  $lustreReadKBytes[$i]/$intSecs,
            $lustreWriteOps[$i]/$intSecs, $lustreWriteKBytes[$i]/$intSecs);
      }

      # These guys are optional and follow ALL the basic stuff     
      for ($i=0; $subOpts=~/B/ && $i<$NumOst; $i++)
      {
        for ($j=0; $j<$numBrwBuckets; $j++)
        { $ostPlot.=sprintf("$SEP%d", $lustreBufRead[$i][$j]/$intSecs); }
        for ($j=0; $j<$numBrwBuckets; $j++)
        { $ostPlot.=sprintf("$SEP%d", $lustreBufWrite[$i][$j]/$intSecs); }
      } 
      writeData(0, $datetime, \$ostPlot, OST, $ZOST, 'ost', \$oneline);
    }

    if ($subOpts=~/D/)
    {
      $blkPlot='';
      for ($i=0; $i<$NumLusDisks; $i++)
      {
        $blkPlot.=sprintf("$SEP%s$SEP%d$SEP%d",
		 	  $LusDiskNames[$i], 
	     		  $lusDiskReads[$i][$LusMaxIndex]/$intSecs, 
             		  $lusDiskReadB[$i][$LusMaxIndex]*0.5/$intSecs);
        for ($j=0; $j<$LusMaxIndex; $j++)
        {
	  $temp=(defined($lusDiskReads[$i][$j])) ? $lusDiskReads[$i][$j]/$intSecs : 0;
          $blkPlot.=sprintf("$SEP%d", $temp);
        }
        $blkPlot.=sprintf("$SEP%d$SEP%d",
	     	   	  $lusDiskWrites[$i][$LusMaxIndex]/$intSecs, 
             		  $lusDiskWriteB[$i][$LusMaxIndex]*0.5/$intSecs);
        for ($j=0; $j<$LusMaxIndex; $j++)
        {
	  $temp=(defined($lusDiskWrites[$i][$j])) ? $lusDiskWrites[$i][$j]/$intSecs : 0;
          $blkPlot.=sprintf("$SEP%d", $temp);
        }
      }
      writeData(0, $datetime, \$blkPlot, BLK, $ZBLK, 'blk', \$online);
    }

    if ($reportCltFlag)
    {
      $cltPlot='';
      if ($subsys=~/LL/)    # either OST details or FS details but not both
      {
        for ($i=0; $i<$NumLustreCltOsts; $i++)
        {
          # when lustre first starts up none of these have values
          $cltPlot.=sprintf("$SEP%s$SEP%s$SEP%d$SEP%d$SEP%d$SEP%d",
              $lustreCltOstFS[$i], $lustreCltOsts[$i],
	      defined($lustreCltLunRead[$i])    ? $lustreCltLunRead[$i]/$intSecs : 0,
	      defined($lustreCltLunReadKB[$i])  ? $lustreCltLunReadKB[$i]/$intSecs : 0,
	      defined($lustreCltLunWrite[$i])   ? $lustreCltLunWrite[$i]/$intSecs : 0, 
	      defined($lustreCltLunWriteKB[$i]) ? $lustreCltLunWriteKB[$i]/$intSecs : 0);
        }
        for ($i=0; $subOpts=~/B/ && $i<$NumLustreCltOsts; $i++)
        {
          for ($j=0; $j<$numBrwBuckets; $j++)
          {
	    $cltPlot.=sprintf("$SEP%3d", $lustreCltRpcRead[$i][$j]/$intSecs);
          }
          for ($j=0; $j<$numBrwBuckets; $j++)
          {
	    $cltPlot.=sprintf("$SEP%3d", $lustreCltRpcWrite[$i][$j]/$intSecs);
          }
        }
      }
      else    # must be FS
      {
        for ($i=0; $i<$NumLustreFS; $i++)
        {
          $cltPlot.=sprintf("$SEP%s$SEP%d$SEP%d$SEP%d$SEP%d",
	    $lustreCltFS[$i],
	    $lustreCltRead[$i]/$intSecs,      $lustreCltReadKB[$i]/$intSecs,   
	    $lustreCltWrite[$i]/$intSecs,     $lustreCltWriteKB[$i]/$intSecs);
	}
        for ($i=0; $subOpts=~/M/ && $i<$NumLustreFS; $i++)
        {
          $cltPlot.=sprintf("$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d",
	    $lustreCltOpen[$i]/$intSecs,      $lustreCltClose[$i]/$intSecs, 
	    $lustreCltGetattr[$i]/$intSecs,   $lustreCltSetattr[$i]/$intSecs, 
	    $lustreCltSeek[$i]/$intSecs,      $lustreCltFsync[$i]/$intSecs,  
            $lustreCltDirtyHits[$i]/$intSecs, $lustreCltDirtyMiss[$i]/$intSecs);
	}
        for ($i=0; $subOpts=~/R/ && $i<$NumLustreFS; $i++)
        {
          $cltPlot.=sprintf("$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d",
            $lustreCltRAPendingTot,  $lustreCltRAHitsTot,    $lustreCltRAMissesTot,
            $lustreCltRANotConTot,   $lustreCltRAMisWinTot,  $lustreCltRALckFailTot,
            $lustreCltRAReadDiscTot, $lustreCltRAZeroLenTot, $lustreCltRAZeroWinTot,
            $lustreCltRA2EofTot,     $lustreCltRAHitMaxTot);
        }
      }
      writeData(0, $datetime, \$cltPlot, CLT, $ZCLT, 'clt', \$oneline);
    }
  }

  #####################
  #    N F S    F i l e
  #####################

  if ($subsys=~/F/)
  {
    $nfsPlot='';
    if ($subOpts=~/2/)
    {
      $nfsPlot.=sprintf("$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP",
            $nfs2Null/$intSecs,   $nfs2Getattr/$intSecs, $nfs2Setattr/$intSecs,
            $nfs2Root/$intSecs,   $nfs2Lookup/$intSecs,  $nfs2Readlink/$intSecs,
            $nfs2Read/$intSecs,   $nfs2Wrcache/$intSecs, $nfs2Write/$intSecs);

      $nfsPlot.=sprintf("%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS",
            $nfs2Create/$intSecs, $nfs2Remove/$intSecs,  $nfs2Rename/$intSecs,
            $nfs2Link/$intSecs,   $nfs2Symlink/$intSecs, $nfs2Mkdir/$intSecs,
            $nfs2Rmdir/$intSecs,  $nfs2Readdir/$intSecs, $nfs2Fsstat/$intSecs);
    }

    if ($subOpts=~/3/)
    {
      $nfsPlot.=sprintf("$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP",
            $nfsNull/$intSecs,   $nfsGetattr/$intSecs, $nfsSetattr/$intSecs,
            $nfsLookup/$intSecs, $nfsAccess/$intSecs,  $nfsReadlink/$intSecs,
            $nfsRead/$intSecs,   $nfsWrite/$intSecs,   $nfsCreate/$intSecs,
            $nfsMkdir/$intSecs,  $nfsSymlink/$intSecs);
      $nfsPlot.=sprintf("%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS",
            $nfsMknod/$intSecs,  $nfsRemove/$intSecs,   $nfsRmdir/$intSecs,
            $nfsRename/$intSecs, $nfsLink/$intSecs,     $nfsReaddir/$intSecs,
            $nfsReaddirplus/$intSecs,                   $nfsFsstat/$intSecs,
            $nfsFsinfo/$intSecs, $nfsPathconf/$intSecs, $nfsCommit/$intSecs);
    }
    writeData(0, $datetime, \$nfsPlot, NFS, $ZNFS, 'nfs', \$oneline);
  }

  #####################
  #    N E T    F i l e
  #####################

  if ($subsys=~/N/)
  {
    $netPlot='';
    for ($i=0; $i<$NumNets; $i++)
    {
      $netPlot.=sprintf("$SEP%s$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS",
                  $netName[$i],
                  $netRxPkt[$i]/$intSecs, $netTxPkt[$i]/$intSecs,
                  $netRxKB[$i]/$intSecs,  $netTxKB[$i]/$intSecs,
                  $netRxErr[$i]/$intSecs, $netRxDrp[$i]/$intSecs,
                  $netRxFifo[$i]/$intSecs,$netRxFra[$i]/$intSecs,
                  $netRxCmp[$i]/$intSecs, $netRxMlt[$i]/$intSecs,
                  $netTxErr[$i]/$intSecs, $netTxDrp[$i]/$intSecs,
                  $netTxFifo[$i]/$intSecs,$netTxColl[$i]/$intSecs,
                  $netTxCar[$i]/$intSecs, $netTxCmp[$i]/$intSecs,
                  $netRxErrs[$i]/$intSecs,$netTxErrs[$i]/$intSecs);
    }
    writeData(0, $datetime, \$netPlot, NET, $ZNET, 'net', \$oneline);
  }

  ############################
  #    I n t e r c o n n e c t
  ############################

  # Quadrics
  if ($subsys=~/X/ && $NumXRails)
  {
    $elanPlot='';
    for ($i=0; $i<$NumXRails; $i++)
    {
      $elanPlot.=sprintf("$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS",
	$elanRx[$i], $elanTx[$i], $elanRxKB[$i], $elanTxKB[$i],
	$elanGet[$i], $elanPut[$i], $elanGetKB[$i], $elanPutKB[$i], 
	$elanComp[$i], $elanCompKB[$i],
	$elanSendFail[$i], $elanNeterrAtomic[$i], $elanNeterrDma[$i]);
    }
    writeData(0, $datetime, \$elanPlot, ELN, $ZELN, 'eln', \$oneline);
  }

  # INFINIBAND
  if ($subsys=~/X/ && $NumHCAs)
  {
    $ibPlot='';
    for ($i=0; $i<$NumHCAs; $i++)
    {
      $ibPlot.=sprintf("$SEP%d$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS$SEP%$FS",
	  $i,
	  $ibRx[$i]/$intSecs,   $ibTx[$i]/$intSecs,
	  $ibRxKB[$i]/$intSecs, $ibTxKB[$i]/$intSecs,
          $ibErrorsTot[$i]);
    }
    writeData(0, $datetime, \$ibPlot, IB, $ZIB, 'ib', \$oneline);
  }

  #######################
  #    T C P    F i l e
  #######################

  if ($subsys=~/T/)
  {
    $tcpPlot='';
    for ($i=0; $i<$NumTcpFields; $i++)
    {
      $tcpPlot.=sprintf("$SEP%$FS", $tcpValue[$i]/$intSecs);
    }
    writeData(0, $datetime, \$tcpPlot, TCP, $ZTCP, 'tcp', \$oneline);
  }

  #    F i n a l    w r i t e

  # This write is necessary to write complete record to terminal or socket.
  writeData(1, $datetime, undef, $LOG, undef, undef, \$oneline)
      if !$logToFileFlag || $addrFlag;
}

# First and formost, this is ONLY used to plot data.  It will send it to the terminal,
# a socket, a data file or a combination of socket and data file.
# Secondly, we only call after processing a complete subsystem so in the case of
# core ones there's a single call but for detail subsystems one per.
# Therefore, when writing to a file, we write the whole string we're passed, but when 
# writing to a terminal or socket, we build up one long string and write it on the
# last call.  Since we can write to any combinations we need to handle them all.
sub writeData
{
  my $eolFlag= shift;
  my $datetime=shift;
  my $string=  shift;
  my $file=    shift;
  my $zfile=   shift;
  my $errtxt=  shift;
  my $strall=  shift;

  # The very last call is special so handle it elsewhere
  if (!$eolFlag)
  {
    # If writing to the terminal or a socket, just concatenate
    # the strings together until the last call.
    if (!$logToFileFlag || $addrFlag)
    {
      $$strall.=$$string;
    }
    elsif ($logToFileFlag)
    {
      # Since we get called with !$eolFlag with partial lines, we always
      # have a separator at the end of the line, so remove it before write.
      my $localCopy=$$string;
      $localCopy=~s/$SEP$//;

      # Each record gets a timestamp and a newline.  In the case of a file
      # header, this will be null and the data will be the header!
      $zfile->gzwrite("$datetime$localCopy\n") or 
	     writeError($errtxt, $zfile)       if  $zFlag;
      print {$file} "$datetime$localCopy\n"    if !$zFlag;
    }
    return;
  }

  # Final Write!!!
  # Doing these two writes this way will allow writing to the
  # terminal AND a socket if we ever want to.
  if (!$addrFlag)
  {
    # final write to terminal
    print "$datetime$$strall\n";
  }

  if ($addrFlag)
  {
    # If a data line, preface with timestamp
    $$strall="$datetime$$strall"    if $strall!~/^#/;

    # Now make sure each line begins with hostname and write to socket
    $$strall=~s/^(.*)$/$Host $1/mg;
    syswrite($socket, "$$strall\n");
  }
}

###################################
#    T e r m i n a l    F o r m a t
###################################

sub printTerm
{
  local $seconds=shift;
  local $usecs=  shift;
  my ($ss, $mm, $hh, $mday, $mon, $year, $line, $i, $j);

  # if we're including date and/or time, do once for whole interval
  $line=$datetime='';
  if ($miniDateFlag || $miniTimeFlag)
  {
    ($ss, $mm, $hh, $mday, $mon, $year)=localtime($seconds);
    $datetime=sprintf("%02d:%02d:%02d", $hh, $mm, $ss);
    $datetime=sprintf("%02d/%02d %s", $mon+1, $mday, $datetime)                   if $options=~/d/;
    $datetime=sprintf("%04d%02d%02d %s", $year+1900, $mon+1, $mday, $datetime)    if $options=~/D/;
    $datetime.=".$usecs"                                                          if ($options=~/m/);
    $datetime.=" ";
  }

  #############################
  #    custom formats
  ############################

  if (!$verboseFlag || $vmstatFlag || $procmemFlag || $procioFlag || $custom ne '')
  {
    if ($custom ne '')
    {
      &$miniName;
      return;
    }

    #    B r i e f

    if ($briefFlag)
    {
      # too long to do inline...
      $line=briefFormatit();
    }

    ##########################
    #	--vmstat
    ##########################

    if ($vmstatFlag)
    {
      if ($options!~/H/ && ($totalCounter % $headerRepeat)==1)
      {
        $line= "${cls}#${miniBlanks}procs ---------------memory (KB)--------------- --swaps-- -----io---- --system-- ----cpu-----\n";
        $line.="#$miniDateTime r  b   swpd   free   buff  cache  inact active   si   so    bi    bo   in    cs us sy  id wa\n";
      }

      my $i=$NumCpus;
      my $usr=$userP[$i]+$niceP[$i];
      my $sys=$sysP[$i]+$irqP[$i]+$softP[$i]+$stealP[$i];
      $line.=sprintf("%s %2d %2d %6s %6s %6s %6s %6s %6s %4d %4d %5d %5d %4d %5d %2d %2d %3d %2d\n",
		$datetime, $procsRun, $procsBlock,
	        cvt($swapUsed,6,1,1),  cvt($memFree,6,1,1),  cvt($memBuf,6,1,1), 
		cvt($memCached,6,1,1), cvt($inactive,6,1,1), cvt($active,6,1,1),
		$swapin/$intSecs, $swapout/$intSecs, $pagein/$intSecs, $pageout/$intSecs,
		$intrpt/$intSecs, $ctxt/$intSecs,
       		$usr, $sys, $idleP[$i], $waitP[$i]);
    }

    ###########################
    #	--procmem
    ###########################

    # if we don't include $interval2Print, it'll print even when no data present
    if ($procmemFlag && $interval2Print)
    {
      # note that the first print interval has a counter of 2 and it's too
      # painful/not worth it to track down...
      print $cls    if $options=~/t/;
      if ($options!~/H/ && ($options=~/t/ || ($interval2Counter % $headerRepeat)==2))
      {
        $line="${cls}#${miniBlanks} PID  User     S VmSize  VmLck  VmRSS VmData  VmStk  VmExe  VmLib Command\n";
      }

      foreach $pid (sort {$a <=> $b} keys %procIndexes)
      {
        $i=$procIndexes{$pid};
        next   	      if (!defined($procSTimeTot[$i]));

        $line.=sprintf("%s%5d%s %-8s %1s %6s %6s %6s %6s %6s %6s %6s %s\n", 
		$datetime, $procPid[$i], $procThread[$i] ? '+' : ' ',
		$procUser[$i], $procState[$i], 
		defined($procVmSize[$i]) ? cvt($procVmSize[$i],6,1,1) : 0, 
		defined($procVmLck[$i])  ? cvt($procVmLck[$i],6,1,1)  : 0,
		defined($procVmRSS[$i])  ? cvt($procVmRSS[$i],6,1,1)  : 0,
		defined($procVmData[$i]) ? cvt($procVmData[$i],6,1,1) : 0,
		defined($procVmStk[$i])  ? cvt($procVmStk[$i],6,1,1)  : 0,  
		defined($procVmExe[$i])  ? cvt($procVmExe[$i],6,1,1)  : 0,
		defined($procVmLib[$i])  ? cvt($procVmLib[$i],6,1,1)  : 0,
		defined($procCmd[$i])    ? (split(/\s+/, $procCmd[$i]))[0] : $procName[$i]);
      }
    }

    ##############################
    #    --procio
    ##############################

    # if we don't include $interval2Print, it'll print even when no data present
    if ($procioFlag && $interval2Print)
    {
      # note that the first print interval has a counter of 2 and it's too
      # painful/not worth it to track down...
      print $cls    if $options=~/t/;
      if ($options!~/H/ && ($options=~/t/ || ($interval2Counter % $headerRepeat)==2))
      {
        $line="${cls}#${miniBlanks} PID  User     S  SysT  UsrT   RKB   WKB  RKBC  WKBC  RSYS  WSYS  CNCL  Command\n";
      }

      foreach $pid (sort {$a <=> $b} keys %procIndexes)
      {
        $i=$procIndexes{$pid};
        next   	      if (!defined($procSTimeTot[$i]));

        $line.=sprintf("%s%5d%s %-8s %1s %s %s ",
		$datetime, $procPid[$i], $procThread[$i] ? '+' : ' ',
		$procUser[$i], $procState[$i],
		cvtT1($procSTime[$i]), cvtT1($procUTime[$i]));
        $line.=sprintf("%5s %5s %5s %5s %5s %5s %5s  %s\n", 
		cvt($procRKB[$i]/$interval2Secs), 
		cvt($procWKB[$i]/$interval2Secs),
		cvt($procRKBC[$i]/$interval2Secs),
		cvt($procWKBC[$i]/$interval2Secs),
		cvt($procRSys[$i]/$interval2Secs),
		cvt($procWSys[$i]/$interval2Secs),
		cvt($procCKB[$i]/$interval2Secs),
        	defined($procCmd[$i])    ? (split(/\s+/, $procCmd[$i]))[0] : $procName[$i]); 
      }
    }

    # This always goes to terminal or socket and is never compressed so we don't need
    # all the options of writeData() [yet].
    printText($line);
    return;
  }

  ############################
  #    V e r b o s e
  ############################

  # we want record breaks (with timestamps) when in verbose mode
  printInterval($seconds, $usecs)    if $options!~/h/;

  # see if we need to clear screen
  print $cls    if $options=~/t/ &&
	        ($options!~/h/ || $totalCounter==1 || ($totalCounter % $headerRepeat)==0);

  if ($subsys=~/c/)
  {
    $i=$NumCpus;
    if (printHeader())
    {
      printText("\n")    if $options!~/t/;
      printText("#$miniFiller CPU$Hyper SUMMARY (INTR, CTXSW & PROC $rate)\n");
      printText("#$miniFiller USER  NICE   SYS  WAIT   IRQ  SOFT STEAL  IDLE  INTR  CTXSW  PROC  RUNQ   RUN   AVG1  AVG5 AVG15\n");
    }
    $line=sprintf("$datetime  %4d  %4d  %4d  %4d  %4d  %4d  %4d  %4d  %4s   %4s  %4d  %4d  %4d  %5.2f %5.2f %5.2f\n",
	    $userP[$i], $niceP[$i], $sysP[$i],   $waitP[$i],
            $irqP[$i],  $softP[$i], $stealP[$i], $idleP[$i], 
	    cvt($intrpt/$intSecs), cvt($ctxt/$intSecs), $proc/$intSecs,
	    $loadQue, $loadRun, $loadAvg1, $loadAvg5, $loadAvg15);
    printText($line);
  }

  if ($subsys=~/C/)
  {
    if (printHeader())
    {
      printText("\n")    if $options!~/t/;
      printText("# SINGLE CPU$Hyper STATISTICS\n");
      printText("#$miniFiller   CPU  USER NICE  SYS WAIT IRQ  SOFT STEAL IDLE\n");
    }

    # if not recorded and user chose -s C don't print line items
    if (defined($userP[0]))
    {
      for ($i=0; $i<$NumCpus; $i++)
      {
        $line=sprintf("$datetime   %4d   %3d  %3d  %3d  %3d  %3d  %3d   %3d  %3d\n",
           $i, 
           $userP[$i], $niceP[$i], $sysP[$i],   $waitP[$i], 
	   $irqP[$i],  $softP[$i], $stealP[$i], $idleP[$i]);
	printText($line);
      }
    } 
  }

  if ($subsys=~/d/)
  {
    if (printHeader())
    {
      printText("\n")    if $options!~/t/;
      printText("# DISK SUMMARY ($rate)\n");
      printText("#${miniFiller}Reads  R-Merged  R-KBytes   Writes  W-Merged  W-KBytes\n");
    }

    $line=sprintf("$datetime%6d    %6d    %6d   %6d    %6d    %6d\n",
      		$dskReadTot/$intSecs,    $dskReadMrgTot/$intSecs,
		$dskReadKBTot/$intSecs,
      		$dskWriteTot/$intSecs,   $dskWriteMrgTot/$intSecs,
		$dskWriteKBTot/$intSecs);
    printText($line);
  }

  if ($subsys=~/D/)
  {
    if (printHeader())
    {
      printText("\n")    if $options!~/t/;
      printText("# DISK STATISTICS ($rate)\n");
      printText("#$miniFiller          <-------reads--------><-------writes------><----------averages---------->  Percent\n");
        printText("#${miniFiller}Name        Ops  Merged  KBytes   Ops  Merged  KBytes  Request  QueLen   Wait SvcTim    Util\n");
    }

    for ($i=0; $i<$NumDisks; $i++)
    {
      # If exception processing in effect, make sure this entry qualities
      next    if $options=~/x/ && $dskRead[$i]/$intSecs<$limIOS && $dskWrite[$i]/$intSecs<$limIOS;

      $line=sprintf("$datetime%-11s %4d    %4d  %6d  %4d  %6d  %6d     %4d  %6d   %4d   %4d     %3d\n",
		$dskName[$i],
		$dskRead[$i]/$intSecs,    $dskReadMrg[$i]/$intSecs,  $dskReadKB[$i]/$intSecs,
		$dskWrite[$i]/$intSecs,   $dskWriteMrg[$i]/$intSecs, $dskWriteKB[$i]/$intSecs,
		$dskRqst[$i], $dskQueLen[$i], $dskWait[$i], $dskSvcTime[$i], $dskUtil[$i]);
      printText($line);
    }
  }

  # server summary different than client summary
  if ($subsys=~/f/ && $subOpts!~/C/)
  {
    if (printHeader())
    {
      printText("\n")    if $options!~/t/;
      printText("# NFS SERVER ($rate)\n");
      printText("#$miniFiller<----------Network-------><----------RPC--------->");
      printText("<---NFS V2--->")     if $subOpts=~/2/;
      printText("<---NFS V3--->")     if $subOpts=~/3/;
      printText("\n");
      printText("#${miniFiller}PKTS   UDP   TCP  TCPCONN  CALLS  BADAUTH  BADCLNT ");
      printText("  READ  WRITE ")    if $subOpts=~/2/;
      printText("  READ  WRITE ")    if $subOpts=~/3/;
      printText("\n");
    }

    $line=sprintf("$datetime %4s  %4s  %4s     %4s   %4s     %4s     %4s ",
	    cvt($nfsPkts/$intSecs),    cvt($nfsUdp/$intSecs), 
	    cvt($nfsTcp/$intSecs),     cvt($nfsTcpConn/$intSecs),
            cvt($rpcCalls/$intSecs),   cvt($rpcBadAuth/$intSecs), 
            cvt($rpcBadClnt/$intSecs));
    $line.=sprintf("  %4s   %4s ", cvt($nfs2Read/$intSecs), cvt($nfs2Write/$intSecs))
	if $subOpts=~/2/;
    $line.=sprintf("  %4s   %4s ", cvt($nfsRead/$intSecs),  cvt($nfsWrite/$intSecs))
	if $subOpts=~/3/;
    $line.="\n"; 
    printText($line);
  }

  # client summary different than server summary
  if ($subsys=~/f/ && $subOpts=~/C/)
  {
    if (printHeader())
    {
      printText("\n")    if $options!~/t/;
      printText("# NFS CLIENT ($rate)\n");
      printText("#$miniFiller<----------RPC--------->");
      printText("<---NFS V2--->")     if $subOpts=~/2/;
      printText("<---NFS V3--->")     if $subOpts=~/3/;
      printText("\n");
      printText("#${miniFiller}CALLS  RETRANS  AUTHREF  ");
      printText("  READ  WRITE ")    if $subOpts=~/2/;
      printText("  READ  WRITE ")    if $subOpts=~/3/;
      printText("\n");
    }

    $line=sprintf("$datetime  %4s     %4s     %4s  ",
            cvt($rpcCalls/$intSecs),   cvt($rpcRetrans/$intSecs), 
            cvt($rpcCredRef/$intSecs));
    $line.=sprintf("  %4s   %4s ", cvt($nfs2Read/$intSecs), cvt($nfs2Write/$intSecs))
	if $subOpts=~/2/;
    $line.=sprintf("  %4s   %4s ", cvt($nfsRead/$intSecs),  cvt($nfsWrite/$intSecs))
	if $subOpts=~/3/;
    $line.="\n"; 
    printText($line);
  }

  if ($subsys=~/F/)
  {
    if ($subOpts=~/2/)
    {
      if (printHeader())
      {
        printText("\n")    if $options!~/t/;
        printText("# NFS V2 ");
        $line=sprintf("%s ($rate)\n", $subOpts!~/C/ ? "SERVER" : "CLIENT");
	printText($line);

        printText("#${miniFiller}NULL GETA SETA ROOT LOOK REDL READ WCAC WRIT CRE8 RMOV RENM LINK SYML MKDR RMDR RDIR FSST\n");
      }

      $line =sprintf("$datetime %4s %4s %4s %4s %4s %4s %4s %4s %4s",
	    cvt($nfs2Null/$intSecs),    cvt($nfs2Getattr/$intSecs), 
            cvt($nfs2Setattr/$intSecs), cvt($nfs2Root/$intSecs),
            cvt($nfs2Lookup/$intSecs),  cvt($nfs2Readlink/$intSecs),
	    cvt($nfs2Read/$intSecs),    cvt($nfs2Wrcache/$intSecs),
            cvt($nfs2Write/$intSecs));
      $line.=sprintf(" %4s %4s %4s %4s %4s %4s %4s %4s %4s\n",
	    cvt($nfs2Create/$intSecs),  cvt($nfs2Remove/$intSecs),   
            cvt($nfs2Rename/$intSecs),  cvt($nfs2Link/$intSecs), 
            cvt($nfs2Symlink/$intSecs), cvt($nfs2Mkdir/$intSecs),
            cvt($nfs2Rmdir/$intSecs),   cvt($nfs2Readdir/$intSecs), 
	    cvt($nfs2Fsstat/$intSecs));
      printText($line);
    }

    if ($subOpts=~/3/)
    {
      if (printHeader())
      {
        printText("\n")    if $options!~/t/;
        printText("# NFS V3 ");
        $line=sprintf("%s ($rate)\n", $subOpts!~/C/ ? "SERVER" : "CLIENT");
	printText($line);

        printText("#${miniFiller}NULL GETA SETA LOOK ACCS RLNK READ WRIT CRE8 MKDR SYML MKND RMOV RMDR RENM LINK RDIR RDR+ FSTA FINF PATH COMM\n");
      }

      $line =sprintf("$datetime %4s %4s %4s %4s %4s %4s %4s %4s %4s %4s %4s",
	    cvt($nfsNull/$intSecs),    cvt($nfsGetattr/$intSecs), 
            cvt($nfsSetattr/$intSecs), cvt($nfsLookup/$intSecs),
            cvt($nfsAccess/$intSecs),  cvt($nfsReadlink/$intSecs),
	    cvt($nfsRead/$intSecs),    cvt($nfsWrite/$intSecs),
            cvt($nfsCreate/$intSecs),  cvt($nfsMkdir/$intSecs),   
            cvt($nfsSymlink/$intSecs));
      $line.=sprintf(" %4s %4s %4s %4s %4s %4s %4s %4s %4s %4s %4s\n",
	    cvt($nfsMknod/$intSecs),       cvt($nfsRemove/$intSecs),   
            cvt($nfsRmdir/$intSecs),       cvt($nfsRename/$intSecs), 
            cvt($nfsLink/$intSecs),        cvt($nfsReaddir/$intSecs),
            cvt($nfsReaddirplus/$intSecs), cvt($nfsFsstat/$intSecs), 
	    cvt($nfsFsinfo/$intSecs),      cvt($nfsPathconf/$intSecs), 
            cvt($nfsCommit/$intSecs));
      printText($line);
    }
  }

  if ($subsys=~/i/)
  {
    if (printHeader())
    {
      printText("\n")    if $options!~/t/;
      printText("# INODE SUMMARY\n");
      printText("#${miniFiller}DCache  ---OpenFiles---           -----SBlock-----   ----DQuot----\n");
      printText("#${miniFiller} Unusd  Handles   % Max    Inode  Handles    % Max   Entry   % Max\n");
    }

    $line=sprintf("$datetime  %5s    %5s   %5.2f    %5s    %5s    %5.2f   %5s   %5.2f\n",
    	cvt($unusedDCache,5), 
	cvt($openFiles,5),   $OFMax ? $openFiles*100/$OFMax : 0, 
	cvt($inodeUsed,5),
    	cvt($superUsed,5),   $SBMax ? $superUsed*100/$SBMax : 0, 
	cvt($dquotUsed,5),   $DSMax ? $dquotUsed*100/$DQMax : 0);
    printText($line);
  }

  # Kinda tricky...
  if ($subsys=~/l/ && ($reportMdsFlag || $reportOstFlag) && ($subOpts=~/[omB]/ || $subOpts!~/D/))
  {
    if (printHeader())
    {
        printText("\n")    if $options!~/t/;
 	printText("# LUSTRE FILESYSTEM SUMMARY\n#$miniFiller");
	if ($reportOstFlag)
	{
          if ($subOpts!~/B/)
          {
            printText("<------------------- OST ------------------>");
          }
       	  else
          {
            printText("<-----------------------reads----------------------- OST ");
            printText("-------------------writes------------------------->");
	  }
	}

        printText("    ")    if $reportOstFlag;
        printText("<------------- MDS --------------->")    if $reportMdsFlag;
	printText("\n#$miniFiller");

        if ($reportOstFlag)
        {
          if ($subOpts!~/B/)
          {
            printText("READ OPS   READ KB      WRITE OPS   WRITE KB");
	  }
	  else
	  {
            $temp='';
  	    foreach my $i (@brwBuckets)
            { $temp.=sprintf(" %3dP", $i); }
	    printText("Rds  RdK$temp Wrts WrtK$temp");
	  }
        }

        printText("    ")    if $reportOstFlag;
	printText("CLOSE   GETATTR     REINT      SYNC")    if $reportMdsFlag;
	printText("\n");
    }

    # Note that we only insert 3 spaces instead of 4 when doing both chunks. 
    # That's because the OST print inserts its own space to get around the
    # '#' above it when only thing on the line.
    $line=$datetime;
    if ($reportOstFlag)
    {
      if ($subOpts!~/B/)
      {
        $line.=sprintf("     %4d    %6d           %4d     %6d",
          $lustreReadOpsTot/$intSecs,  $lustreReadKBytesTot/$intSecs,
          $lustreWriteOpsTot/$intSecs, $lustreWriteKBytesTot/$intSecs);
      }
      else
      {
        $line.=sprintf("%4s %4s",
	  cvt($lustreReadOpsTot/$intSecs), cvt($lustreReadKBytesTot/$intSecs));
        for ($i=0; $i<$numBrwBuckets; $i++)
        {
	  $line.=sprintf(" %4s", cvt($lustreBufReadTot[$i]/$intSecs));
        }

        $line.=sprintf(" %4s %4s",
  	  cvt($lustreWriteOpsTot/$intSecs), cvt($lustreWriteKBytesTot/$intSecs));
        for ($i=0; $i<$numBrwBuckets; $i++)
        {
	  $line.=sprintf(" %4s", cvt($lustreBufWriteTot[$i]/$intSecs));
        }
      }
    }

    $line.=sprintf("   ")    if $reportOstFlag;
    if ($reportMdsFlag)
    {
      $line.=sprintf(" %5d     %5d     %5d     %5d",
	  $lustreMdsClose/$intSecs, $lustreMdsGetattr/$intSecs, 
	  $lustreMdsReint/$intSecs, $lustreMdsSync/$intSecs)
	      unless $options=~/x/ && $lustreMdsReint/$intSecs<$limLusReints;
    }
    $line.="\n"    if $line ne '';
    printText($line);
  }

  if ($subsys=~/l/ && ($reportMdsFlag || $reportOstFlag) && $subOpts=~/D/)
  {
    if (printHeader())
    {
      printText("\n")    if $options!~/t/;
      printText("# LUSTRE DISK BLOCK LEVEL SUMMARY\n#$miniFiller");
      $temp='';

      # not even room to preceed sizes with r/w's.
      foreach my $i (@diskBuckets)
      { 
        #last    if $i>$LustreMaxBlkSize;
        if ($i<1000) { $temp.=sprintf(" %3sK", $i) } else { $temp.=sprintf(" %3dM", $i/1024); }
      }
      printText("Rds  RdK$temp Wrts WrtK$temp\n");
    }

    # Now do the data
    $line=$datetime;
    $line.=sprintf("%4s %4s",
	  cvt($lusDiskReadsTot[$LusMaxIndex]/$intSecs), 
          cvt($lusDiskReadBTot[$LusMaxIndex]*0.5/$intSecs));
    for ($i=0; $i<$LusMaxIndex; $i++)
    {
      $line.=sprintf(" %4s", cvt($lusDiskReadsTot[$i]/$intSecs));
    }
    $line.=sprintf(" %4s %4s",
	  cvt($lusDiskWritesTot[$LusMaxIndex]/$intSecs), 
          cvt($lusDiskWriteBTot[$LusMaxIndex]*0.5/$intSecs));
    for ($i=0; $i<$LusMaxIndex; $i++)
    {
      $line.=sprintf(" %4s", cvt($lusDiskWritesTot[$i]/$intSecs));
    }
    printText("$line\n");
  }

  if ($subsys=~/L/ && $reportOstFlag && ($subOpts=~/B/ || $subOpts!~/D/))
  {
    if (printHeader())
    {
      # build ost header, and when no date/time make it even 1 char less.
      $temp="Ost". ' 'x$OstWidth;
      $temp=substr($temp, 0, $OstWidth);
      $temp=substr($temp, 0, $OstWidth-2).' '    if $miniFiller eq '';

      # When doing dates/time shift first field over 1 to the left;
      $fill1=$fill2='';
      if ($miniFiller ne '')
      {
        $fill1=substr($miniFiller, 0, length($miniFiller)-1);
        $fill2=' ';
      }

      printText("\n")    if $options!~/t/;
      printText("# LUSTRE FILESYSTEM SINGLE OST STATISTICS\n");
      if ($subOpts!~/B/)
      {
        printText("#$fill1$temp$fill2 Read Ops   Read KB      Write Ops   Write KB\n");
      }
      else
      {
        $temp2='';
        foreach my $i (@brwBuckets)
        { $temp2.=sprintf(" %3dK", $i); }
        printText("#$fill1$temp$fill2   Rds  RdK$temp2 Wrts WrtK$temp2\n");
      }
    }

    for ($i=0; $i<$NumOst; $i++)
    {
      # If exception processing in effect, make sure this entry qualities
      next    if $options=~/x/ && 
	      $lustreReadKBytes[$i]/$intSecs<$limLusKBS &&
	      $lustreWriteKBytes[$i]/$intSecs<$limLusKBS;

      $line='';
      if ($subOpts!~/B/)
      {
        $line.=sprintf("$datetime%-${OstWidth}s     %4d    %6d           %4d     %6d\n",
	       $lustreOsts[$i],
	       $lustreReadOps[$i]/$intSecs,  $lustreReadKBytes[$i]/$intSecs, 
	       $lustreWriteOps[$i]/$intSecs, $lustreWriteKBytes[$i]/$intSecs);
      }
      else
      {
        $line.=sprintf("$datetime%-${OstWidth}s  %4s %4s",
	       $lustreOsts[$i], 
	       cvt($lustreReadOps[$i]/$intSecs), 
               cvt($lustreReadKBytes[$i]/$intSecs));
        for ($j=0; $j<$numBrwBuckets; $j++)
        {
	  $line.=sprintf(" %4s", cvt($lustreBufRead[$i][$j]/$intSecs));
        }

        $line.=sprintf(" %4s %4s",
  	       cvt($lustreWriteOps[$i]/$intSecs), 
               cvt($lustreWriteKBytes[$i]/$intSecs));
        for ($j=0; $j<$numBrwBuckets; $j++)
        {
	  $line.=sprintf(" %4s", cvt($lustreBufWrite[$i][$j]/$intSecs));
        }
	$line.="\n";
      }
      printText($line);
    }
  }

  if ($subsys=~/L/ && $subOpts=~/D/)
  {
    if (printHeader())
    {
      printText("\n")    if $options!~/t/;
      printText("# LUSTRE DISK BLOCK LEVEL DETAIL (units are 512 bytes)\n#$miniFiller");
      $temp='';
      foreach my $i (@diskBuckets)
      { 
        #last    if $i>$LustreMaxBlkSize;
        if ($i<1000) { $temp.=sprintf(" %3sK", $i) } else { $temp.=sprintf(" %3dM", $i/1024); }
      }
      printText("DISK Rds  RdK$temp Wrts WrtK$temp\n");
    }

    # Now do the data
    for ($i=0; $i<$NumLusDisks; $i++)
    {
      $line=$datetime;
      $line.=sprintf("%4s %4s %4s",
	     $LusDiskNames[$i], 
	     cvt($lusDiskReads[$i][$LusMaxIndex]/$intSecs), 
             cvt($lusDiskReadB[$i][$LusMaxIndex]*0.5/$intSecs));
      for ($j=0; $j<$LusMaxIndex; $j++)
      {
	$temp=(defined($lusDiskReads[$i][$j])) ? cvt($lusDiskReads[$i][$j]/$intSecs) : 0;
        $line.=sprintf(" %4s", $temp);
      }
      $line.=sprintf(" %4s %4s",
	     cvt($lusDiskWrites[$i][$LusMaxIndex]/$intSecs), 
             cvt($lusDiskWriteB[$i][$LusMaxIndex]*0.5/$intSecs));
      for ($j=0; $j<$LusMaxIndex; $j++)
      {
	$temp=(defined($lusDiskWrites[$i][$j])) ? cvt($lusDiskWrites[$i][$j]/$intSecs) : 0;
        $line.=sprintf(" %4s", $temp);
      }
      printText("$line\n");
    }
  }

  # NOTE - there are a number of different types of formats here and we're always going
  # to include reads/writes with all of them!
  if ($subsys=~/l/ && $reportCltFlag)
  {
    # If time for common header, do it...
    if (printHeader())
    {
      printText("\n")    if $options!~/t/;
      printText("# LUSTRE CLIENT SUMMARY");
      printText(":")    if $subOpts=~/[BMR]/;
      printText(" RPC-BUFFERS (pages)")    if $subOpts=~/B/;
      printText(" METADATA")               if $subOpts=~/M/;
      printText(" READAHEAD")              if $subOpts=~/R/;
      printText("\n");
    }

    # If exception processing must be above minimum
    if ($options!~/x/ || 
	    $lustreCltReadKBTot/$intSecs>=$limLusKBS ||
            $lustreCltWriteKBTot/$intSecs>=$limLusKBS)
    {
      if ($subOpts!~/[BMR]/)
      {
        printText("#$miniFiller Reads ReadKB  Writes WriteKB\n")
		if printHeader();

        $line=sprintf("$datetime %6d %6d  %6d  %6d\n",
	    $lustreCltReadTot/$intSecs,      $lustreCltReadKBTot/$intSecs,   
	    $lustreCltWriteTot/$intSecs,     $lustreCltWriteKBTot/$intSecs);
        printText($line);
      }

      if ($subOpts=~/B/)
      {
        if (printHeader())
        {
          $temp='';
  	  foreach my $i (@brwBuckets)
          { $temp.=sprintf(" %3dK", $i); }
	  printText("#${miniFiller}Rds  RdK$temp Wrts WrtK$temp\n");
        }

        $line="$datetime";
        $line.=sprintf("%4s %4s", cvt($lustreCltReadTot/$intSecs), cvt($lustreCltReadKBTot/$intSecs));
        for ($i=0; $i<$numBrwBuckets; $i++)
        {
	  $line.=sprintf(" %4s", cvt($lustreCltRpcReadTot[$i]/$intSecs));
        }

        $line.=sprintf(" %4s %4s",
  	       cvt($lustreCltWriteTot/$intSecs), 
               cvt($lustreCltWriteKBTot/$intSecs));
        for ($i=0; $i<$numBrwBuckets; $i++)
        {
	  $line.=sprintf(" %4s", cvt($lustreCltRpcWriteTot[$i]/$intSecs));
        }
        printText("$line\n");
      }

      if ($subOpts=~/M/)
      {
        printText("#$miniFiller Reads ReadKB  Writes WriteKB  Open Close GAttr SAttr  Seek Fsynk DrtHit DrtMis\n")
		if printHeader();

        $line=sprintf("$datetime %6d %6d  %6d  %6d %5d %5d %5d %5d %5d %5d %6d %6d\n",
	    $lustreCltReadTot/$intSecs,      $lustreCltReadKBTot/$intSecs,   
	    $lustreCltWriteTot/$intSecs,     $lustreCltWriteKBTot/$intSecs,   
	    $lustreCltOpenTot/$intSecs,      $lustreCltCloseTot/$intSecs, 
	    $lustreCltGetattrTot/$intSecs,   $lustreCltSetattrTot/$intSecs, 
	    $lustreCltSeekTot/$intSecs,      $lustreCltFsyncTot/$intSecs,  
            $lustreCltDirtyHitsTot/$intSecs, $lustreCltDirtyMissTot/$intSecs);
        printText($line);
      }

      if ($subOpts=~/R/)
      {
        printText("#$miniFiller Reads ReadKB  Writes WriteKB  Pend  Hits Misses NotCon MisWin LckFal  Discrd ZFile ZerWin RA2Eof HitMax\n")
		if printHeader();

        $line=sprintf("$datetime %6d %6d  %6d  %6d %5d %5d %6d %6d %6d %6d %6d %6d %6d %6d %6d\n",
	    $lustreCltReadTot/$intSecs,       $lustreCltReadKBTot/$intSecs,   
	    $lustreCltWriteTot/$intSecs,      $lustreCltWriteKBTot/$intSecs,   
            $lustreCltRAPendingTot/$intSecs,  $lustreCltRAHitsTot/$intSecs,
            $lustreCltRAMissesTot/$intSecs,   $lustreCltRANotConTot/$intSecs,
            $lustreCltRAMisWinTot/$intSecs,   $lustreCltRALckFailTot/$intSecs,
            $lustreCltRAReadDiscTot/$intSecs, $lustreCltRAZeroLenTot/$intSecs,
            $lustreCltRAZeroWinTot/$intSecs,  $lustreCltRA2EofTot/$intSecs,
            $lustreCltRAHitMaxTot/$intSecs);
        printText($line);
      }
    }
  }

  # NOTE -- there are 2 levels of details, both 'L' and 'LL', but 'LL' not compatible
  # with -OB or -OM or -OR
  if ($subsys=~/L/ && $reportCltFlag)
  {
    if (printHeader())
    {
      # we need to build filesystem header, and when no date/time make it even 1
      # char less.
      $temp="Filsys". ' 'x$FSWidth;
      $temp=substr($temp, 0, $FSWidth);
      $temp=substr($temp, 0, $FSWidth-2).' '    if $miniFiller eq '';

      # When doing dates/time, we also need to shift first field over 1 to the left;
      $fill1=$fill2='';
      if ($miniFiller ne '')
      {
        $fill1=substr($miniFiller, 0, length($miniFiller)-1);
        $fill2=' ';
      }

      printText("\n")    if $options!~/t/;
      printText("# LUSTRE CLIENT DETAIL");
      printText(":")    if $subOpts=~/[BMR]/;
      printText(" RPC-BUFFERS (pages)")    if $subOpts=~/B/;
      printText(" METADATA")               if $subOpts=~/M/;
      printText(" READAHEAD")              if $subOpts=~/R/;
      printText("\n");
    }

    if ($subsys=~/LL/)
    {
      # Never for M or R
      if ($subOpts!~/B/)
      {
        $fill3=' 'x($OstWidth-3);
        printText("#$fill1$temp$fill2 Ost$fill3  Reads ReadKB  Writes WriteKB\n")
	    if printHeader();
        for ($i=0; $i<$NumLustreCltOsts; $i++)
        {
          $line=sprintf("$datetime%-${FSWidth}s %-${OstWidth}s %6d %6d  %6d  %6d\n",
		    $lustreCltOstFS[$i], $lustreCltOsts[$i],
		    $lustreCltLunRead[$i]/$intSecs,
	    	    defined($lustreCltLunReadKB[$i]) ? $lustreCltLunReadKB[$i]/$intSecs : 0,
	    	    $lustreCltLunWrite[$i]/$intSecs,
	   	    defined($lustreCltLunWriteKB[$i]) ? $lustreCltLunWriteKB[$i]/$intSecs : 0);
          printText($line);
        }
      }

      if ($subOpts=~/B/)
      {
        $fill3=' 'x($OstWidth-3);
        if (printHeader())
        {
          $temp2=' 'x(length("$fill1$temp$fill2 Ost$fill3 "));
          $temp3='';
  	  foreach my $i (@brwBuckets)
          { $temp3.=sprintf(" %3dK", $i); }
	  printText("#$fill1$temp$fill2 Ost$fill3 Rds  RdK$temp3 Wrts WrtK$temp3\n");
        }
        for ($clt=0; $clt<$NumLustreCltOsts; $clt++)
        {
          $line=sprintf("$datetime%-${FSWidth}s %-${OstWidth}s", $lustreCltOstFS[$clt], $lustreCltOsts[$clt]);
          $line.=sprintf("%4s %4s", 
                 cvt($lustreCltLunRead[$clt]/$intSecs),
                 cvt($lustreCltLunReadKB[$clt]/$intSecs));

          for ($i=0; $i<$numBrwBuckets; $i++)
          {
	    $line.=sprintf(" %4s", cvt($lustreCltRpcRead[$clt][$i]/$intSecs));
          }

          $line.=sprintf(" %4s %4s",
    	         cvt($lustreCltLunWrite[$clt]/$intSecs), 
                 cvt($lustreCltLunWriteKB[$clt]/$intSecs));
          for ($i=0; $i<$numBrwBuckets; $i++)
          {
	    $line.=sprintf(" %4s", cvt($lustreCltRpcWrite[$clt][$i]/$intSecs));
          }
          printText("$line\n");
        }
      }
    }
    else
    {
      $commonLine= "#$fill1$temp$fill2  Reads ReadKB  Writes WriteKB";
      if ($subOpts!~/[MR]/)
      {
        printText("$commonLine\n")    if printHeader();
        for ($i=0; $i<$NumLustreFS; $i++)
        {
          $line=sprintf("$datetime%-${FSWidth}s %6d %6d  %6d  %6d\n",
	    $lustreCltFS[$i],
	    $lustreCltRead[$i]/$intSecs,      $lustreCltReadKB[$i]/$intSecs,   
	    $lustreCltWrite[$i]/$intSecs,     $lustreCltWriteKB[$i]/$intSecs);
          printText($line);
        }
      }

      if ($subOpts=~/M/)
      {
        printText("$commonLine  Open Close GAttr SAttr  Seek Fsync DrtHit DrtMis\n")
		if printHeader();
        {
          for ($i=0; $i<$NumLustreFS; $i++)
          {
            $line=sprintf("$datetime%-${FSWidth}s %6d %6d  %6d  %6d %5d %5d %5d %5d %5d %5d %6d %6d\n",
	    $lustreCltFS[$i],
	    $lustreCltRead[$i]/$intSecs,      $lustreCltReadKB[$i]/$intSecs,   
	    $lustreCltWrite[$i]/$intSecs,     $lustreCltWriteKB[$i]/$intSecs,   
	    $lustreCltOpen[$i]/$intSecs,      $lustreCltClose[$i]/$intSecs, 
	    $lustreCltGetattr[$i]/$intSecs,   $lustreCltSetattr[$i]/$intSecs, 
	    $lustreCltSeek[$i]/$intSecs,      $lustreCltFsync[$i]/$intSecs,  
            $lustreCltDirtyHits[$i]/$intSecs, $lustreCltDirtyMiss[$i]/$intSecs);
            printText($line);
          }
        }
      }

      if ($subOpts=~/R/)
      {
        printText("$commonLine  Pend  Hits Misses NotCon MisWin LckFal  Discrd ZFile ZerWin RA2Eof HitMax\n")
		if printHeader();
        {
          for ($i=0; $i<$NumLustreFS; $i++)
          {
            $line=sprintf("$datetime%-${FSWidth}s %6d %6d  %6d  %6d %5d %5d %6d %6d %6d %6d %6d %6d %6d %6d %6d\n",
	    $lustreCltFS[$i],
	    $lustreCltReadTot/$intSecs,       $lustreCltReadKBTot/$intSecs,   
	    $lustreCltWriteTot/$intSecs,      $lustreCltWriteKBTot/$intSecs,   
            $lustreCltRAPendingTot/$intSecs,  $lustreCltRAHitsTot/$intSecs,
            $lustreCltRAMissesTot/$intSecs,   $lustreCltRANotConTot/$intSecs,
            $lustreCltRAMisWinTot/$intSecs,   $lustreCltRALckFailTot/$intSecs,
            $lustreCltRAReadDiscTot/$intSecs, $lustreCltRAZeroLenTot/$intSecs,
            $lustreCltRAZeroWinTot/$intSecs,  $lustreCltRA2EofTot/$intSecs,
            $lustreCltRAHitMaxTot/$intSecs);
            printText($line);
          }
        }
      }
    }
  }

  if ($subsys=~/m/)
  {
    if (printHeader())
    {
      # Note that sar does page sizes in numbers of pages, not bytes
      # only 2.6 kernels AND collectl 1.5.6 have extra memory goodies
      printText("\n")    if $options!~/t/;
      printText("# MEMORY STATISTICS\n");
      if ($kernel2_4 || $recVersion lt '1.5.6')
      {
        $line=sprintf("#$miniFiller<-------------Physical Memory-----------><-----------Swap----------><-Inactive-><Pages%s>\n", substr($rate, 0, 4));
      printText($line);
      printText("#$miniFiller   TOTAL    USED    FREE    BUFF  CACHED     TOTAL    USED    FREE     TOTAL     IN    OUT\n");
      }
      else
      {
        $line=sprintf("#$miniFiller<------------------------Physical Memory-----------------------><-----------Swap----------><-Inactive-><Pages%s>\n", substr($rate, 0, 4));
        printText($line);
        printText("#$miniFiller   TOTAL    USED    FREE    BUFF  CACHED    SLAB  MAPPED  COMMIT     TOTAL    USED    FREE     TOTAL     IN    OUT\n");
      }
    }

    $line=sprintf("$datetime  %7s %7s %7s %7s %7s ",
            cvt($memTot,7,1,1),   cvt($memUsed,7,1,1),   cvt($memFree,7,1,1),
	    cvt($memBuf,7,1,1),   cvt($memCached,7,1,1));

    $line.=sprintf("%7s %7s %7s ", cvt($memSlab,7,1,1), cvt($memMap,7,1,1), cvt($memCommit,7,1,1))
	    if $kernel2_6 && ($recVersion ge '1.5.6');

    $line.=sprintf("  %7s %7s %7s   %7s %6d %6d\n",
	    cvt($swapTotal,7,1,1),  cvt($swapUsed,7,1,1), cvt($swapFree,7,1,1),
            cvt($inactive,7,1,1),   $pagein/$intSecs,     $pageout/$intSecs);

    printText($line);
  }

  if ($subsys=~/n/)
  {
    if (printHeader())
    {
      printText("\n")    if $options!~/t/;
      printText("# NETWORK SUMMARY ($rate)\n");
      printText("#${miniFiller}InPck  InErr OutPck OutErr   Mult   ICmp   OCmp    IKB    OKB\n");
    }

    $line=sprintf("$datetime%6d %6d %6d %6d %6d %6d %6d %6d %6d\n",
	$netRxPktTot/$intSecs, $netRxErrsTot/$intSecs, 
	$netTxPktTot/$intSecs, $netTxErrsTot/$intSecs,
	$netRxMltTot/$intSecs, $netRxCmpTot/$intSecs, $netTxCmpTot/$intSecs,
	$netRxKBTot/$intSecs,  $netTxKBTot/$intSecs);
    printText($line);
  }

  if ($subsys=~/N/)
  {
    if (printHeader())
    {
      $tempName=' 'x($NetWidth-5).'Name';
      printText("\n")    if $options!~/t/;
      printText("# NETWORK STATISTICS ($rate)\n");
      printText("#${miniFiller}Num   $tempName  InPck  InErr OutPck OutErr   Mult   ICmp   OCmp    IKB    OKB\n");
    }

    for ($i=0; $i<$netIndex; $i++)
    {
        $line=sprintf("$datetime %3d  %${NetWidth}s %6d %6d %6d %6d %6d %6d %6d %6d %6d\n",
	$i, $netName[$i], 
	$netRxPkt[$i]/$intSecs, $netRxErrs[$i]/$intSecs, 
	$netTxPkt[$i]/$intSecs, $netTxErrs[$i]/$intSecs,
	$netRxMlt[$i]/$intSecs, $netRxCmp[$i]/$intSecs, $netTxCmp[$i]/$intSecs,
	$netRxKB[$i]/$intSecs,  $netTxKB[$i]/$intSecs);
      printText($line);
    }
  }

  if ($subsys=~/s/)
  {
    if (printHeader())
    {
      printText("\n")    if $options!~/t/;
      printText("# SOCKET STATISTICS\n");
      printText("#${miniFiller}      <-------------Tcp------------->   Udp   Raw   <---Frag-->\n");
      printText("#${miniFiller}Used  Inuse Orphan    Tw  Alloc   Mem  Inuse Inuse  Inuse   Mem\n");
    }

    $line=sprintf("$datetime%5d  %5d  %5d %5d  %5d %5d  %5d %5d  %5d %5d\n",
           $sockUsed, $sockTcp, $sockOrphan, $sockTw, $sockAlloc, $sockMem,
	   $sockUdp, $sockRaw, $sockFrag, $sockFragM);
    printText($line);
  }

  if ($subsys=~/t/)
  {
    if (printHeader())
    {
      printText("\n")    if $options!~/t/;
      printText("# TCP SUMMARY ($rate)\n");
      printText("#${miniFiller} PureAcks HPAcks   Loss FTrans\n");
    }

    $line=sprintf("$datetime    %6d %6d %6d %6d\n",
	$tcpValue[27]/$intSecs,  $tcpValue[28]/$intSecs,
	$tcpValue[40]/$intSecs,  $tcpValue[45]/$intSecs);
    printText($line);
  }

  if ($subsys=~/E/ && $interval3Print)
  {
    if (printHeader())
    {
      printText("\n")    if $options!~/t/;
      printText("# ENVIRONMENTAL STATISTICS\n");
      printText("#${miniFiller}<---------- Fan ----------><---- Power ---><Temperature>\n");
      printText("#${miniFiller}ID Status1    Status2      ID  Status      ID  Temp\n");
    }

    $max=$NumFans;
    $max=$NumPwrs    if $NumPwrs>$max;
    $max=$NumTemps   if $NumTemps>$max;

    for ($i=1; $i<$max; $i++)
    {
      $fanNum=$i;
      $fanStat=$fanStat[$i];
      $fanText=$fanText[$i];
      $fanNum=$fanStat=$fanText=''    if !defined($fanStat);

      $pwrNum=$i;
      $pwrStat=$pwrStat[$i];
      $pwrNum=$pwrStat=''             if !defined($pwrStat);

      $tempNum=$i;
      $tempTemp=$tempTemp[$i];
      $tempNum=$tempTemp=''           if !defined($tempTemp);

      $line=sprintf("$datetime%2s  %-10s %-10s   %2s  %-10s  %2s  %-10s\n",
	$fanNum, $fanStat, $fanText, $pwrNum, $pwrStat, $tempNum, $tempTemp);
      printText($line);
    }
  }

  if ($subsys=~/x/)
  {
    if ($NumXRails)
    {
      if (printHeader())
      {
        printText("\n")    if $options!~/t/;
        printText("# ELAN4 SUMMARY ($rate)\n");
        printText("#${miniFiller}OpsIn OpsOut   KBIn  KBOut Errors\n");
      }

      $elanErrors=$elanSendFailTot+$elanNeterrAtomicTot+$elanNeterrDmaTot;
      $line=sprintf("$datetime%6d %6d %6d %6d %6d\n",
	$elanRxTot/$intSecs,   $elanTxTot/$intSecs,
	$elanRxKBTot/$intSecs, $elanTxKBTot/$intSecs,
	$elanErrors/$intSecs);
      printText($line);
    }

    if ($NumHCAs)
    {
      if (printHeader())
      {
        printText("\n")    if $options!~/t/;
        printText("# INFINIBAND SUMMARY ($rate)\n");
        printText("#${miniFiller} OpsIn  OpsOut   KB-In  KB-Out  Errors\n");
      }

      $line=sprintf("$datetime%7d %7d %7d %7d %7d\n",
	$ibRxTot/$intSecs,   $ibTxTot/$intSecs,
	$ibRxKBTot/$intSecs, $ibTxKBTot/$intSecs,
	$ibErrorsTotTot);
      printText($line);
    }
  }

  if ($subsys=~/X/)
  {
    if ($NumXRails)
    {
      if (printHeader())
      {
        printText("\n")    if $options!~/t/;
        printText("# ELAN4 STATISTICS ($rate)\n");
        printText("#${miniFiller}Rail  OpsIn OpsOut  KB-In KB-Out OpsGet OpsPut KB-Get KB-Put   Comp CompKB SndErr AtmErr DmsErr\n");
      }

      for ($i=0; $i<$NumXRails; $i++)
      {
        $line=sprintf("$datetime %4d %6d %6d %6d %6d %6d %6d %6d %6d %6d %6d %6d %6d %6d\n",
	  $i, 
	  $elanRx[$i]/$intSecs,       $elanTx[$i]/$intSecs,
	  $elanRxKB[$i]/$intSecs,     $elanTxKB[$i]/$intSecs, 
	  $elanGet[$i]/$intSecs,      $elanPut[$i]/$intSecs,
	  $elanGetKB[$i]/$intSecs,    $elanPutKB[$i]/$intSecs, 
	  $elanComp[$i]/$intSecs,     $elanCompKB[$i]/$intSecs, 
	  $elanSendFail[$i]/$intSecs, $elanNeterrAtomic[$i]/$intSecs, 
	  $elanNeterrDma[$i]/$intSecs);
        printText($line);
      }
    }

    if ($NumHCAs)
    {
      if (printHeader())
      {
        printText("\n")    if $options!~/t/;
        printText("# INFINIBAND STATISTICS ($rate)\n");
        printText("#${miniFiller}HCA    OpsIn  OpsOut   KB-In  KB-Out  Errors\n");
      }

      for ($i=0; $i<$NumHCAs; $i++)
      {
        $line=sprintf("$datetime  %2d  %7d %7d %7d %7d %7d\n",
	  $i,
	  $ibRx[$i]/$intSecs,   $ibTx[$i]/$intSecs,
	  $ibRxKB[$i]/$intSecs, $ibTxKB[$i]/$intSecs,
	  $ibErrorsTot[$i]);
        printText($line);
      }
    }
  }

  if ($subsys=~/y/ && $interval2Print && $interval2Counter>1)
  {
    if ($slabinfoFlag)
    {
      if (printHeader())
      {
        printText("\n")    if $options!~/t/;
        printText("# SLAB SUMMARY\n");
        printText("#${miniFiller}<------------Objects------------><--------Slab Allocation-------><--Caches--->\n");
        printText("#${miniFiller}  InUse   Bytes    Alloc   Bytes   InUse   Bytes   Total   Bytes  InUse  Total\n");
      }

      $line=sprintf("$datetime %7s %7s  %7s %7s  %6s %7s  %6s %7s %6s %6s\n",
          cvt($slabObjActTotal,7),  cvt($slabObjActTotalB,7,0,1), 
	  cvt($slabObjAllTotal,7),  cvt($slabObjAllTotalB,7,0,1),
	  cvt($slabSlabActTotal,6), cvt($slabSlabActTotalB,7,0,1),
	  cvt($slabSlabAllTotal,6), cvt($slabSlabAllTotalB,7,0,1),
   	  cvt($slabNumAct,6),       cvt($slabNumTot,6));
      printText($line);
    }
    else
    {
      if (printHeader())
      {
        printText("\n")    if $options!~/t/;
        printText("# SLAB SUMMARY\n");
        printText("#${miniFiller}<---Objects---><-Slabs-><-----memory----->\n");
        printText("#${miniFiller} In Use   Avail  Number      Used    Total\n");
      }
      $line=sprintf("$datetime %7s %7s %7s   %7s  %7s\n",
          cvt($slabNumObjTot,7),  cvt($slabObjAvailTot,7), cvt($slabNumTot,7),  
	  cvt($slabUsedTot,7,0,1), cvt($slabTotalTot,7,0,1));
      printText($line);
    }
  }

  if ($subsys=~/Y/ && $interval2Print && $interval2Counter>1)
  {
    if ($slabinfoFlag)
    {
      if (printHeader())
      {
        printText("\n")    if $options!~/t/;
        printText("# SLAB DETAIL\n");
        printText("#${miniFiller}                      <-----------Objects----------><---------Slab Allocation------>\n");
        printText("#${miniFiller}Name                  InUse   Bytes   Alloc   Bytes   InUse   Bytes   Total   Bytes\n");
      }

      for ($i=0; $i<$slabIndexNext; $i++)
      {
        # the first test is for filtering out zero-size slabs and the
        # second for slabs that didn't change this during this interval
        next    if ($options=~/s/ && $slabSlabAllTot[$i]==0) ||
 	           ($options=~/S/ && $slabSlabAct[$i]==0 && $slabSlabAll[$i]==0);

        $line=sprintf("$datetime%-20s %7s %7s  %6s %7s  %6s %7s  %6s %7s\n",
          $slabName[$i],
	  cvt($slabObjActTot[$i],6),    cvt($slabObjActTotB[$i],7,0,1), 
  	  cvt($slabObjAllTot[$i],6),    cvt($slabObjAllTotB[$i],7,0,1),
	  cvt($slabSlabActTot[$i],6),   cvt($slabSlabActTotB[$i],7,0,1),
	  cvt($slabSlabAllTot[$i],6),   cvt($slabSlabAllTotB[$i],7,0,1));

        printText($line);
      }
    }
    else
    {
      if (printHeader())
      {
        printText("\n")    if $options!~/t/;
        printText("# SLAB DETAIL\n");
        printText("#${miniFiller}                             <----------- objects -----------><--- slabs ---><----- memory ----->\n");
        printText("#${miniFiller}Slab Name                    Size  /slab   In Use     Avail    SizeK  Number      UsedK    TotalK\n");
      }

      foreach my $first (sort keys %slabfirst)
      {
	my $slab=$slabfirst{$first};

        # as for regular slabs, the first test is for filtering out zero-size
        # slabs and the second for slabs that didn't change this during this interval
	my $numObjects=$slabdata{$slab}->{objects};
        my $numSlabs=  $slabdata{$slab}->{slabs};
        next    if ($options=~/s/ && $slabdata{$slab}->{objects}==0) ||
 	           ($options=~/S/ && $slabdata{$slab}->{lastobj}==$numObjects &&
				     $slabdata{$slab}->{lastslabs}==$numSlabs);

        printf "$datetime%-25s  %7d  %5d  %7d  %7d     %5d %7d   %8d  %8d\n",
            $first,
	    $slabdata{$slab}->{slabsize},
	    $slabdata{$slab}->{objper},
	    $numObjects,
	    $slabdata{$slab}->{avail},
            ($PageSize<<$slabdata{$slab}->{order})/1024,
	    $numSlabs, 
	    $slabdata{$slab}->{used}/1024, 
	    $slabdata{$slab}->{total}/1024;

        # So we can tell when something changes
        $slabdata{$slab}->{lastobj}=  $numObjects;
        $slabdata{$slab}->{lastslabs}=$numSlabs;
      }
    }
  }

  # we only print if data collected this interval AND not first time.
  if ($subsys=~/Z/ && $interval2Print && $interval2Counter>1)
  {
    # In --top mode, make sure we get a new header with each interval
    $totalCounter=1    if $numTop;
    if (printHeader())
    {
      $temp2='';
      if ($numTop)
      {
        print $cls;
        $temp2= " ".(split(/\s+/,localtime($seconds)))[3];
        $temp2.=sprintf(".%03d", $usecs)    if $options=~/m/;
      }
      printText("\n")    if $options!~/t/;
      $temp1=($options=~/F/) ? "(faults are cumulative)" : "(faults are $rate)";
      printText("# PROCESS SUMMARY $temp1$temp2\n");

      $tempHdr= "#${miniFiller} PID  User     PR  PPID S   VSZ   RSS  SysT  UsrT Pct  AccuTime ";
      $tempHdr.=" RKB  WKB "    if $processIOFlag;
      $tempHdr.="MajF MinF Command\n";
      printText($tempHdr);
    }

    # When doing top, the pids with the most accumumated user/sys time get printed first
    my %procSort;
    if ($numTop)
    {
      foreach my $pid (keys %procIndexes)
      {
	my $pTime=$procSTime[$procIndexes{$pid}]+$procUTime[$procIndexes{$pid}];
        my $key=sprintf("%06d:%06d", 999999-$pTime, $pid);
        $procSort{$key}=$pid;
      }
    }
    # otherwise we print in order of ascending pid
    else
    {
      foreach $pid (keys %procIndexes)
      {
        $procSort{sprintf("%06d", $pid)}=$pid;
      }
    }

    my $procCount=0;
    foreach $key (sort keys %procSort)
    {
      # if we had partial data for this pid don't try to print!
      $i=$procIndexes{$procSort{$key}};
      #print ">>>SKIP PRINTING DATA for pid $key  i: $i"
      #	      if (!defined($procSTimeTot[$i]));
      next   	      if (!defined($procSTimeTot[$i]));

      last    if $numTop && ++$procCount>$numTop;

      # Handle -oF
      if ($options=~/F/)
      {
	$majFlt=$procMajFltTot[$i];
	$minFlt=$procMinFltTot[$i];
      }
      else
      {
        $majFlt=$procMajFlt[$i]/$interval2Secs;
	$minFlt=$procMinFlt[$i]/$interval2Secs;
      }

      $line=sprintf("$datetime%5d%s %-8s %2s %5d %1s %5s %5s %s %s %s %s ", 
		$procPid[$i],  $procThread[$i] ? '+' : ' ',
		$procUser[$i], $procPri[$i],
		$procPpid[$i], $procState[$i], 
		defined($procVmSize[$i]) ? cvt($procVmSize[$i],4,1) : 0, 
		defined($procVmRSS[$i])  ? cvt($procVmRSS[$i],4,1)  : 0,
		cvtT1($procSTime[$i]), cvtT1($procUTime[$i]), 
		cvtP($procSTime[$i]+$procUTime[$i]),
		cvtT2($procSTimeTot[$i]+$procUTimeTot[$i]));
      $line.=sprintf("%4s %4s ", 
		cvt($procRKB[$i]/$interval2Secs),
		cvt($procWKB[$i]/$interval2Secs))    if $processIOFlag;
      $line.=sprintf("%4s %4s %s\n", 
		cvt($majFlt), cvt($minFlt),
		defined($procCmd[$i]) ? (split(/\s+/,$procCmd[$i]))[0] : $procName[$i]);
      printText($line);
    }
  }
}

# this routine detects and 'fixes' counters that have wrapped
# *** warning ***  It appears that partition 'use' counters wrap at wordsize/100 
# on an ia32 (these are pretty pesky to actually catch).  There may be more and 
# they may behave differently on different architectures (though I tend to doubt 
# it) so the best we can do is deal with them when we see them.  It also looks like
#  elan counters are divided by 1MB before reporting so we have to deal with them too
sub fix
{
  my $counter=shift;

  # if we're a smaller architecture than the number itself, we should still be
  # ok because perl isn't restricted by word size.
  if ($counter<0)
  {
    my $divisor= shift;
    my $archFlag=shift;
    my ($add, $wordsize);

    # if the archflag set in param3, we use the max counter size for this 
    # architecture.  otherwise we just use a 32 bit wide word.
    $wordsize=defined($archFlag) ? $maxword : $word32;

    # only adjust divisor when we're told to do so in param2.
    $add=defined($divisor) ? $wordsize/$divisor : $wordsize;
    $counter+=$add;
  }
  return($counter);
}

# unitCounter  0 -> none, 1 -> K, etc (devide by $divisor this # times)
# divisor 0 -> /1000  1 -> /1024
sub cvt
{
  my $field=shift;
  my $width=shift;
  my $unitCounter=shift;
  my $divisorType=shift;
  my ($divisor, $units);

  $width=4          if !defined($width);
  $unitCounter=0    if !defined($unitCounter);
  $divisorType=0    if !defined($divisorType);
  $field=int($field+.5);    # round up in case <1

  # This is tricky, because if the value fits within the width, we
  # must also be sure the unit counter is 0 otherwise both may not
  # fit.  Naturally in 'wide' mode we aways report the complete value
  # and we never print units with values of 0.
  return($field)    if ($field==0) || ($unitCounter<1 && length($field)<=$width) || $wideFlag;

  my $last=0;
  $divisor=($divisorType==0) ? 1000 : $OneKB;
  while (length($field)>=$width)
  {
    $last=$field;
    $field=int($field/$divisor);
    $unitCounter++;
  }
  $units=substr(" KMGTP", $unitCounter, 1);
  my $result="$field$units";
  
  # Messy, but I hope reasonable efficient.  We're only applying this to
  # fields >= 'G' and options g/G!  Furthermore, for -oG we only reformat 
  # when single digit because no room for 2.
  if ($units=~/[GTP]/ && $options=~/g/i && (my $len=length($field))!=3)
  {
    if ($options=~/G/ && $len==1)
    {
      $result="$field.".substr($last, $len, 2-$len).'G';
    }
    elsif ($options=~/g/)
    {
      $result="${field}g".substr($last, $len, 3-$len);
    }
  }
  return($result);
}

# Time Format1 - convert time in jiffies to something ps-esque
# Seconds.hsec only (not suitable for longer times such as accumulated cpu)
sub cvtT1
{
  my $jiffies=shift;
  my $nsFlag= shift;
  my ($secs, $hsec);

  # set formatting for minutes according to 'no space' flag
  $MF=(!$nsFlag) ? '%2d' : '%d';

  $secs=int($jiffies/$HZ);
  $jiffies=$jiffies-$secs*$HZ;
  $hsec=$jiffies/$HZ*100;
  return(sprintf("$MF.%02d", $secs, $hsec));
}

# Time Format1 - convert time in jiffies to something ps-esque
# we're not doing hours to save a couple of columns
sub cvtT2
{
  my $jiffies=shift;
  my $nsFlag= shift;
  my ($hour, $mins, $secs, $time, $hsec);

  # set formatting for minutes according to 'no space' flag
  $MF=(!$nsFlag) ? '%3d' : '%d';

  $secs=int($jiffies/$HZ);
  $jiffies=$jiffies-$secs*$HZ;
  $hsec=$jiffies/$HZ*100;

  $mins=int($secs/60);
  $secs=$secs-$mins*60;
  $time=sprintf("$MF:%02d", $mins, $secs);
  $time.=sprintf('.%02d', $hsec);
  return($time);
}

sub cvtP
{
  my $jiffies=shift;
  my ($secs, $percent);

  $secs=$jiffies/$HZ;
  $percent=sprintf("%3d", 100*$secs/$interval2Secs);
  return($percent);
}

#####################################################
#    S - E x p r e s s i o n    S u p p o r t
#####################################################

sub printSexprRaw
{
  sexprHeader()    if !$sexprHeaderWritten;

  # 1 extra level of indent (looks prettier) for XC
  my $pad=$XCFlag ? '  ' : '';
  my $sumFlag=$subsys=~/[cdfilmnstx]/ ? 1 : 0;
  my $detFlag=$subsys=~/[CDN]/        ? 1 : 0;

  my $cpuSumString=$cpuDetString='';
  if ($subsys=~/c/i)
  {
    if ($subsys=~/c/)
    {
      my ($uTot, $nTot, $sTot, $iTot, $wTot, $irTot, $soTot, $stTot)=(0,0,0,0,0,0,0,0);
      for (my $i=0; $i<$NumCpus; $i++)
      {
        $uTot+= $userLast[$i];
        $nTot+= $niceLast[$i];
        $sTot+= $sysLast[$i];
        $iTot+= $idleLast[$i];
        $wTot+= $waitLast[$i];
        $irTot+=$irqLast[$i];
        $soTot+=$softLast[$i];
        $stTot+=$stealLast[$i];
      }
      $cpuSumString.="$pad(cputotals (user $uTot) (nice $nTot) (sys $sTot) (idle $iTot) (wait $wTot) ";
      $cpuSumString.=               "(irq $irTot) (soft $soTot) (steal $stTot))\n";
      $cpuSumString.="$pad(ctxint (ctx $ctxtLast) (int $intrptLast) (proc $procLast) (runq $loadQue))\n";
    }

    if ($subsys=~/C/)
    {
      my ($name, $userTot, $niceTot, $sysTot, $idleTot, $waitTot)=('','','','','','');
      for (my $i=0; $i<$NumCpus; $i++)
      {
        $name.=   "cpu$i ";
        $userTot.="$userLast[$i] ";
        $niceTot.="$userLast[$i] ";
        $sysTot.= "$userLast[$i] ";
        $idleTot.="$userLast[$i] ";
        $waitTot.="$userLast[$i] ";
      }
      $name=~s/ $//;       $userTot=~s/ $//;    $niceTot=~s/ $//;
      $sysTot=~s/ $//;     $idleTot=~s/ $//;    $waitTot=~s/ $//;

      $cpuDetString.="$pad(cpuinfo\n";
      $cpuDetString.="$pad  (name $name)\n";
      $cpuDetString.="$pad  (user $userTot)\n";
      $cpuDetString.="$pad  (nice $niceTot)\n";
      $cpuDetString.="$pad  (sys $sysTot)\n";
      $cpuDetString.="$pad  (idle $idleTot)\n";
      $cpuDetString.="$pad  (wait $waitTot))\n";
    }
  }

  my $diskSumString=$diskDetString='';
  if ($subsys=~/d/i)
  {
    if ($subsys=~/d/)
    {
      my ($dRTot, $dRkbTot, $dWTot, $dWkbTot)=(0,0,0,0);
      for (my $i=0; $i<$NumDisks; $i++)
      {
        $dRTot+=   $dskFieldsLast[$i][0];
        $dRkbTot+= $dskFieldsLast[$i][2];
        $dWTot+=   $dskFieldsLast[$i][4];
        $dWkbTot+= $dskFieldsLast[$i][6];
      }
      $diskSumString.="$pad(disktotals (reads $dRTot) (readkbs $dRkbTot) (writes $dWTot) (writekbs $dWkbTot))\n";
    }

    if ($subsys=~/D/)
    {
      my ($dName, $dRTot, $dRkbTot, $dWTot, $dWkbTot)=('','','','','');
      for (my $i=0; $i<$NumDisks; $i++)
      {
        $dName.=   "$dskName[$i] ";
        $dRTot.=   "$dskFieldsLast[$i][0] ";
        $dRkbTot.= "$dskFieldsLast[$i][2] ";
        $dWTot.=   "$dskFieldsLast[$i][4] ";
        $dWkbTot.= "$dskFieldsLast[$i][6] ";
      }
      $dName=~s/ $//;
      $dRTot=~s/ $//;  $dRkbTot=~s/ $//;
      $dWTot=~s/ $//;  $dWkbTot=~s/ $//;
      $diskDetString.="$pad(diskinfo\n";
      $diskDetString.="$pad  (name $dName)\n";
      $diskDetString.="$pad  (reads $dRTot)\n";
      $diskDetString.="$pad  (readkbs $dRkbTot)\n";
      $diskDetString.="$pad  (writes $dWTot)\n";
      $diskDetString.="$pad  (writekbs $dWkbTot))\n";
    }
  }

  my $nfsString='';
  if ($subsys=~/f/)
  {
    $nfsString= "$pad(nfsinfo (read $nfsValuesLast[6]) (write $nfsValuesLast[7]) (calls $rpcCallsLast))\n";
  }

  my $inodeString='';
  if ($subsys=~/i/)
  {
    $inodeString= "$pad(inodeinfo (unuseddcache $unusedDCache) (openfiles $openFiles) ";
    $inodeString.="(inodeused $inodeUsed) (superuer $superUsed)(dquotused $dquotUsed))\n";
  }

  # No lustre details, at least not for now...
  my $lusSumString='';
  if ($subsys=~/l/)
  {
    if ($CltFlag)
    {
      my ($reads, $readKBs, $writes, $writeKBs)=(0,0,0,0);
      for (my $i=0; $i<$NumLustreFS; $i++)
      {
        $reads+=   $lustreCltReadLast[$i];
        $readKBs+= $lustreCltReadKBLast[$i];
        $writes+=  $lustreCltWriteLast[$i];
        $writeKBs+=$lustreCltWriteKBLast[$i];
      }
      $lusSumString.="$pad(lusclt (reads $reads) (readkbs $readKBs) (writes $writes) (writekbs $writeKBs))\n";
    }

    if ($OstFlag)
    {
      my ($reads, $readKBs, $writes, $writeKBs)=(0,0,0,0);
      for (my $i=0; $i<$NumOst; $i++)
      {
        $reads+=   $lustreReadOpsLast[$i];
        $readKBs+= $lustreReadKBytesLast[$i];
        $writes+=  $lustreWriteOpsLast[$i];
        $writeKBs+=$lustreWriteKBytesLast[$i];
      }
      $lusSumString.="$pad(lusoss (reads $reads) (readkbs $readKBs) (writes $writes) (writekbs $writeKBs))\n";
    }

    if ($MdsFlag)
    {
      $lusSumString.="$pad(lusmds (close $lustreMdsCloseLast) (getattr $lustreMdsGetattrLast) ";
      $lusSumString.="(reint $lustreMdsReintLast) (sync $lustreMdsSyncLast))\n";
    }
  }

  my $memString='';
  if ($subsys=~/m/)
  {
    $memString= "$pad(meminfo (memtot $memTot) (memused $memUsed) (memfree $memFree) ";
    $memString.="(memshared $memShared) (membuf $memBuf) (memcached $memCached) ";
    $memString.="(memslab $memSlab) (memmap $memMap))\n";
  }

  my $netSumString=$netDetString='';
  if ($subsys=~/n/i)
  {
    if ($subsys=~/n/)
    {
      my ($kbinT, $pktinT, $kboutT, $pktoutT)=(0,0,0,0);
      for ($i=0; $i<$netIndex; $i++)
      {
        next    if $netName=~/lo|sit/;
        $kbinT+=  $netRxKBLast[$i];
        $pktinT+= $netRxPktLast[$i];
        $kboutT+= $netTxKBLast[$i];
        $pktoutT+=$netTxPktLast[$i];
      }
      $netSumString= "$pad(nettotals (netkbin $kbinT) (netpktin $pktinT) (netkbout $kboutT) (netpktout $pktoutT))\n";
    }

    if ($subsys=~/N/)
    {
      my ($name, $kbinT, $pktinT, $kboutT, $pktoutT)=('','','','','');
      for ($i=0; $i<$netIndex; $i++)
      {
        next    if $netName[$i]=~/lo|sit/;
        $name.=   "$netName[$i] ";
        $kbinT.=  "$netRxKBLast[$i] ";
        $pktinT.= "$netRxPktLast[$i] ";
        $kboutT.= "$netTxKBLast[$i] ";
        $pktoutT.="$netTxPktLast[$i] ";
      }
      $name=~s/ $|://g;    $kbinT=~s/ $//;    $pktinT=~s/ $//; 
      $kboutT=~s/ $//;     $pktoutT=~s/ $//;
      $netDetString= "$pad(netinfo\n";
      $netDetString.="$pad  (name $name)\n";
      $netDetString.="$pad  (netkbin $kbinT)\n";
      $netDetString.="$pad  (netpktin $pktinT)\n";
      $netDetString.="$pad  (netkbout $kboutT)\n";
      $netDetString.="$pad  (netpktout $pktoutT))\n";
    }
  }

  my $sockString='';
  if ($subsys=~/s/)
  {
    $sockString= "$pad(sockinfo (sockused $sockUsed) (socktcp $sockTcp) (sockorphan $sockOrphan) (socktw $sockTw) (sockalloc $sockAlloc) (sockmem $sockMem)";
    $sockString.="(sockudp $sockUdp) (sockraw $sockRaw) (sockfrag $sockFrag) (sockfragm $sockFragM))\n";
  }

  my $tcpString='';
  if ($subsys=~/t/)
  {
    $tcpString="$pad(tcpinfo (tcppureack $tcpLast[27]) (tcphpack $tcpLast[28]) (tcploss $tcpLast[40]) (tcpftrans $tcpLast[45]))\n";
  }

  my $intString='';
  if ($subsys=~/x/i)
  {
    my ($kbInT, $pktInT, $kbOutT, $pktOutT)=(0,0,0,0);
    for (my $i=0; $i<$NumXRails; $i++)
    {
      $kbInT+=  $elanRxMBLast[$i]*1024;
      $pktInT+= $elanRxLast[$i];
      $kbOutT+= $elanTxMBLast[$i]*1024;
      $pktOutT+=$elanTxLast[$i];
    }

    $port=$HCAPortActive;
    for (my $i=0; $i<$NumHCAs; $i++)
    {
      $kbInT+=  $ibFieldsLast[$i][$port][13];
      $pktInT+= $ibFieldsLast[$i][$port][15];
      $kbOutT+= $ibFieldsLast[$i][$port][12];
      $pktOutT+=$ibFieldsLast[$i][$port][14];
    }
    $intString="$pad(iconnect (intkbin $kbInT) (intpktin $pktInT) (intkbout $kbOutT) (intpktout $pktOutT))\n";
  }

  # Build up as a single string
  $sexprRec='';
  $sexprRec.="(collectl_summary\n"    if $XCFlag && $sumFlag;
  $sexprRec.="$pad(sample (time $lastSecs))\n"    if $sumFlag;
  $sexprRec.="$cpuSumString$diskSumString$nfsString$inodeString$memString$netSumString";
  $sexprRec.="$lusSumString$sockString$tcpString$intString";
  $sexprRec.=")\n"                    if $XCFlag && $sumFlag;

  $sexprRec.="(collectl_detail\n"     if $XCFlag && $detFlag;
  $sexprRec.="$pad(sample (time $lastSecs))\n"    if !$sumFlag;
  $sexprRec.="$cpuDetString$diskDetString$netDetString";
  $sexprRec.=")\n"                    if $XCFlag && $detFlag;

  # if a file was specified, write the data to it
  if ($sexprDir ne '')
  {
    open  SEXPR, ">$sexprDir/S" or logmsg("F", "Couldn't create '$sexprDir/S'");
    print SEXPR  $sexprRec;
    close SEXPR;
  }

  if ($addrFlag || $sexprDir eq '')
  {
    printText($sexprRec);
  }
}

sub printSexprRate
{
  sexprHeader()    if !$sexprHeaderWritten;

  # 1 extra level of indent (looks prettier) for XC
  my $pad=$XCFlag ? '  ' : '';
  my $sumFlag=$subsys=~/[cdfilmnstx]/ ? 1 : 0;
  my $detFlag=$subsys=~/[CDN]/        ? 1 : 0;

  my $cpuSumString=$cpuDetString='';
  if ($subsys=~/c/i)
  {
    if ($subsys=~/c/)
    {
      # CPU utilization is a % and we don't want to report fractions
      my $i=$NumCpus;
      $cpuSumString.=sprintf("$pad(cputotals (user %d) (nice %d) (sys %d) (wait %d) (irq %d) (soft %d) (steal %d) (idle %d))\n",
		$userP[$i], $niceP[$i], $sysP[$i], $waitP[$i], $irqP[$i], $softP[$i], $stealP[$i], $idleP[$i]);
      $cpuSumString.=sprintf("$pad(ctxint (ctx %d) (int %d) (proc %d) (runq $loadQue))\n",
		$ctxt/$intSecs, $intrpt/$intSecs, $proc/$intSecs);
    }

    if ($subsys=~/C/)
    {
      my ($name, $userTot, $niceTot, $sysTot, $waitTot, $irqTot, $softT, $stealTot, $idleTot)=('','','','','','','','','');
      for (my $i=0; $i<$NumCpus; $i++)
      {
        $name.=    "cpu$i ";
        $userTot.= "$userP[$i] ";
        $niceTot.= "$niceP[$i] ";
        $sysTot.=  "$sysP[$i] ";
        $waitTot.= "$waitP[$i] ";
	$irqTot.=  "$irqP[$i] ";
	$softTot.= "$softP[$i] ";
	$stealTot.="$stealP[$i] ";
        $idleTot.="$idleP[$i] ";
      }
      $name=~s/ $//;       $userTot=~s/ $//;    $niceTot=~s/ $//;
      $sysTot=~s/ $//;     $waitTot=~s/ $//;    $irqTot=~s/ $//;
      $softTot=~s/ $//;    $stealTot=~s/ $//;   $idleTot=~s/ $//;
      $cpuDetString.="$pad(cpuinfo\n";
      $cpuDetString.="$pad  (name $name)\n";
      $cpuDetString.="$pad  (user $userTot)\n";
      $cpuDetString.="$pad  (nice $niceTot)\n";
      $cpuDetString.="$pad  (sys $sysTot)\n";
      $cpuDetString.="$pad  (wait $waitTot))\n";
      $cpuDetString.="$pad  (irq $irqTot)\n";
      $cpuDetString.="$pad  (soft $softTot)\n";
      $cpuDetString.="$pad  (steal $stealTot)\n";
      $cpuDetString.="$pad  (idle $idleTot)\n";
    }
  }

  my $diskSumString=$diskDetString='';
  if ($subsys=~/d/i)
  {
    if ($subsys=~/d/)
    {
      $diskSumString.=sprintf("$pad(disktotals (reads %d)) (readkbs %d) (writes %d) (writekbs %d))\n", 
		$dskReadTot/$intSecs,  $dskReadKBTot/$intSecs, 
		$dskWriteTot/$intSecs, $dskWriteKBTot/$intSecs);
    }

    if ($subsys=~/D/)
    {
      my ($dName, $dRTot, $dRkbTot, $dWTot, $dWkbTot)=('','','','','');
      for (my $i=0; $i<$NumDisks; $i++)
      {
        $dName.=   "$dskName[$i] ";
        $dRTot.=   sprintf("%d ", $dskRead[$i]/$intSecs);
        $dRkbTot.= sprintf("%d ", $dskReadKB[$i]/$intSecs);
        $dWTot.=   sprintf("%d ", $dskWrite[$i]/$intSecs);
        $dWkbTot.= sprintf("%d ", $dskWriteKB[$i]/$intSecs);
      }
      $dName=~s/ $//;
      $dRTot=~s/ $//;  $dRkbTot=~s/ $//;
      $dWTot=~s/ $//;  $dWkbTot=~s/ $//;
      $diskDetString.="$pad(diskinfo\n";
      $diskDetString.="$pad  (name $dName)\n";
      $diskDetString.="$pad  (reads $dRTot)\n";
      $diskDetString.="$pad  (readkbs $dRkbTot)\n";
      $diskDetString.="$pad  (writes $dWTot)\n";
      $diskDetString.="$pad  (writekbs $dWkbTot))\n";
    }
  }

  my $nfsString='';
  if ($subsys=~/f/)
  {
    $nfsString=sprintf("$pad(nfsinfo (read %d) (write %d) (calls %d))\n", 
	$nfsRead/$intSecs, $nfsWrite/$intSecs, $rpcCalls/$intSecs);
  }

  my $inodeString='';
  if ($subsys=~/i/)
  {
    $inodeString= "$pad(inodeinfo (unuseddcache $unusedDCache) (openfiles $openFiles) ";
    $inodeString.="(inodeused $inodeUsed) (superuer $superUsed)(dquotused $dquotUsed))\n";
  }

  # No lustre details, at least not for now...
  my $lusSumString='';
  if ($subsys=~/l/)
  {
    if ($CltFlag)
    {
      $lusSumString.=sprintf("$pad(lusclt (reads %d) (readkbs %d) (writes %d) (writekbs %d))\n",
            $lustreCltReadTot/$intSecs,      $lustreCltReadKBTot/$intSecs,
            $lustreCltWriteTot/$intSecs,     $lustreCltWriteKBTot/$intSecs);
    }

    if ($OstFlag)
    {
      $lusSumString.=sprintf("$pad(lusoss (reads %d) (readkbs %d) (writes %d) (writekbs %d))\n", 
		$lustreReadOpsTot/$intSecs,  $lustreReadKBytesTot/$intSecs, 
		$lustreWriteOpsTot/$intSecs, $lustreWriteKBytesTot/$intSecs);
    }

    if ($MdsFlag)
    {
      $lusSumString.=sprintf("$pad(lusmds (close %d) (getattr %d) (reint %d) (sync %d)\n", 
		$lustreMdsClose/$intSecs, $lustreMdsGetattr/$intSecs, 
		$lustreMdsReint/$intSecs, $lustreMdsSync/$intSecs);
    }
  }

  my $memString='';
  if ($subsys=~/m/)
  {
    $memString= "$pad(meminfo (memtot $memTot) (memused $memUsed) (memfree $memFree) ";
    $memString.="(memshared $memShared) (membuf $memBuf) (memcached $memCached) ";
    $memString.="(memslab $memSlab) (memmap $memMap))\n";
  }

  my $netSumString=$netDetString='';
  if ($subsys=~/n/i)
  {
    if ($subsys=~/n/)
    {
      $netSumString=sprintf("$pad(nettotals (netkbin %d) (netpktin %d) (netkbout %d) (netpktout %d))\n",
                $netRxKBTot/$intSecs, $netRxPktTot/$intSecs,
		$netTxKBTot/$intSecs, $netTxPktTot/$intSecs);
    }

    if ($subsys=~/N/)
    {
      my ($name, $kbinT, $pktinT, $kboutT, $pktoutT)=('', '','','','');
      for ($i=0; $i<$netIndex; $i++)
      {
        next    if $netName[$i]=~/lo|sit/;
        $name.=  "$netName[$i] ";
        $kbinT.=  sprintf("%d ", $netRxKB[$i]/$intSecs);
        $pktinT.= sprintf("%d ", $netRxPkt[$i]/$intSecs);
        $kboutT.= sprintf("%d ", $netTxKB[$i]/$intSecs);
        $pktoutT.=sprintf("%d ", $netTxPkt[$i]/$intSecs);
      }
      $name=~s/ $|://g;    $kbinT=~s/ $//;    $pktinT=~s/ $//; 
      $kboutT=~s/ $//;     $pktoutT=~s/ $//;
      $netDetString= "$pad(netinfo\n";
      $netDetString.="$pad  (name $name)\n";
      $netDetString.="$pad  (netkbin $kbinT)\n";
      $netDetString.="$pad  (netpktin $pktinT)\n";
      $netDetString.="$pad  (netkbout $kboutT)\n";
      $netDetString.="$pad  (netpktout $pktoutT))\n";
    }
  }

  my $sockString='';
  if ($subsys=~/s/)
  {
    $sockString= "$pad(sockinfo (sockused $sockUsed) (socktcp $sockTcp) (sockorphan $sockOrphan) (socktw $sockTw) (sockalloc $sockAlloc) (sockmem $sockMem)";
    $sockString.="(sockudp $sockUdp) (sockraw $sockRaw) (sockfrag $sockFrag) (sockfragm $sockFragM))\n";
  }

  my $tcpString='';
  if ($subsys=~/t/)
  {
    $tcpString=sprintf("$pad(tcpinfo (tcppureack %d) (tcphpack %d) (tcploss %d) (tcpftrans %d))\n",
	        $tcpValue[27]/$intSecs,  $tcpValue[28]/$intSecs,
        	$tcpValue[40]/$intSecs,  $tcpValue[45]/$intSecs);
  }

  my $intString='';
  if ($subsys=~/x/i)
  {
    if ($NumXRails)
    {
      $kbInT=  $elanRxKBTot;
      $pktInT= $elanRxTot;
      $kbOutT= $elanTxKBTot;
      $pktOutT=$elanTxTot;
    }

    if ($NumHCAs)
    {
      $kbInT=  $ibRxKBTot;
      $pktInT= $ibRxTot;
      $kbOutT= $ibTxKBTot;
      $pktOutT=$ibTxTot;
    }
    $intString=sprintf("$pad(iconnect (intkbin %d) (intpktin %d) (intkbout %d) (intpktout %d))\n", 
	$kbInT/$intSecs, $pktInT/$intSecs, $kbOutT/$intSecs, $pktOutT/$intSecs);
  }

  $sexprRec='';
  $sexprRec.="(collectl_summary\n"    if $XCFlag && $sumFlag;
  $sexprRec.="$pad(sample (time $lastSecs))\n"    if $sumFlag;
  $sexprRec.="$cpuSumString$diskSumString$nfsString$inodeString$memString$netSumString";
  $sexprRec.="$lusSumString$sockString$tcpString$intString";
  $sexprRec.=")\n"                    if $XCFlag && $sumFlag;

  $sexprRec.="(collectl_detail\n"     if $XCFlag && $detFlag;
  $sexprRec.="$pad(sample (time $lastSecs))\n"    if !$sumFlag;
  $sexprRec.="$cpuDetString$diskDetString$netDetString";
  $sexprRec.=")\n"                    if $XCFlag && $detFlag;

  if ($sexprDir ne '')
  {
    open  SEXPR, ">$sexprDir/S" or logmsg("F", "Couldn't create '$sexprDir/S'");
    print SEXPR  $sexprRec;
    close SEXPR;
  }

  if ($addrFlag || $sexprDir eq '')
  {
    printText($sexprRec);
  }
}

sub sexprHeader
{
  # 1 extra level of indent (looks prettier) for XC
  my $pad=$XCFlag ? '  ' : '';
  my $sumFlag=$subsys=~/[cdfilmnstx]/ ? 1 : 0;
  my $detFlag=$subsys=~/[CDN]/        ? 1 : 0;

  print "Create sexpr header file: $sexprDir/S\n"    if $debug & 8192;
  $sexprHeaderWritten=1;

  $sexprHdr='';
  $sexprHdr.="(collect_summary\n"    if $XCFlag && $sumFlag;
  $sexprHdr.="$pad(sample (time var))\n";
  $sexprHdr.="$pad(cputotals (user val) (nice val) (sys val) (idle val) (wait val) (irq val) (soft val) (steal val))\n"
	if $subsys=~/c/;
  $sexprHdr.="$pad(ctxint (ctx val) (int val) (proc val) (runq val))\n"
	if $subsys=~/c/;
  $sexprHdr.="$pad(disktotals (reads val) (readkbs val) (writes val) (writekbs val))\n"
	if $subsys=~/d/;
  $sexprHdr.="$pad(nfsinfo (read val) (write val) (calls val))\n"
        if $subsys=~/f/;
  $sexprHdr.="$pad(inodeinfo (unuseddcache val) (openfiles val) (inodeused val) (superuer val)(dquotused val))\n"
	if $subsys=~/i/;
  $sexprHdr.="$pad(lusclt (reads val) (readkbs val) (writes val) (writekbs al))\n"
	if $subsys=~/l/ && $CltFlag;
  $sexprHdr.="$pad(lusmds (close val) (getattr val) (reint val) (sync val))\n"
	if $subsys=~/l/ && $MdsFlag;
  $sexprHdr.="$pad(lusoss (reads val) (readkbs val) (writes val) (writekbs val))\n"
	if $subsys=~/l/ && $OstFlag;
  $sexprHdr.="$pad(meminfo (memtot val) (memused val) (memfree val) (memshared val) (membuf val) (memcached val) (memslab val) (memmap val))\n"
        if $subsys=~/m/;
  $sexprHdr.="$pad(nettotals (netkbin val) (netpktin val) (netkbout val) (netpktout val))\n"
        if $subsys=~/n/;
  $sexprHdr.="$pad(sockinfo (sockused val) (socktcp val) (sockorphan val) (socktw val) (sockalloc val) (sockmem val)(sockudp val) (sockraw val) (sockfrag val) (sockfragm val))\n"
        if $subsys=~/s/;
  $sexprHdr.="$pad(tcpinfo (tcppureack val) (tcphpack val) (tcploss val) (tcpftrans val))\n"
        if $subsys=~/t/;
  $sexprHdr.="$pad(iconnect (intkbin val) (intpktin val) (intkbout val) (intpktout val))\n"
        if $subsys=~/x/;
  $sexprHdr.=")\n"    if $XCFlag && $sumFlag;

  $sexprHdr.="(collect_detail \n"    if $XCFlag && $subsys=~/[CDN]/;
  if ($subsys=~/C/)
  {
    my $names='';
    $sexprHdr.="$pad(cpuinfo\n";
    for (my $i=0; $i<$NumCpus; $i++)
    {
      $names.="cpu$i ";
    }
    $sexprHdr.="$pad  (name $names)\n";
    $sexprHdr.="$pad  (user $names)\n";
    $sexprHdr.="$pad  (nice $names)\n";
    $sexprHdr.="$pad  (sys $names)\n";
    $sexprHdr.="$pad  (idle $names)\n";
    $sexprHdr.="$pad  (wait $names)\n";
  }

  if ($subsys=~/D/)
  {
    my $names='';
    $sexprHdr.="$pad(diskinfo\n";
    for (my $i=0; $i<$NumDisks; $i++)
    {
      $names.="$dskName[$i] ";
    }
    $sexprHdr.="$pad  (name $names)\n";
    $sexprHdr.="$pad  (reads $names)\n";
    $sexprHdr.="$pad  (readkbs $names)\n";
    $sexprHdr.="$pad  (writes $names)\n";
    $sexprHdr.="$pad  (writekbs $names)\n";
  }

  if ($subsys=~/N/)
  {
    my $names='';
    $sexprHdr.="$pad(netinfo\n";
    for (my $i=0; $i<$NumNets; $i++)
    {
      next    if $netName[$i]=~/lo|sit/;
      $names.="$netName[$i] ";
    }
    $names=~s/://g;
    $sexprHdr.="$pad  (name $names)\n";
    $sexprHdr.="$pad  (netkbin $names)\n";
    $sexprHdr.="$pad  (netpktin $names)\n";
    $sexprHdr.="$pad  (netkbout $names)\n";
    $sexprHdr.="$pad  (netpktout $names)\n";
  }
  $sexprHdr.=")\n"    if $detFlag && $XCFlag;

  if ($sexprDir ne '')
  {
    open  SEXPR, ">$sexprDir/#" or logmsg("F", "Couldn't create '$sexprDir/#'");
    print SEXPR  $sexprHdr;
    close SEXPR;
  }

  if ($addrFlag || $sexprDir eq '')
  {
    printText($sexprHdr);
  }

}

sub printInterval
{
  my $seconds=shift;
  my $usecs=  shift;

  my $date=localtime($seconds);
  if ($options=~/m/)
  {
    my ($dow, $mon, $day, $time, $year)=split(/ /, $date);
    $date="$dow $mon $day $time.$usecs $year";
  }

  # Since we're passing 2 lines to printText(), when $addrFlag set we need to
  # plug in the host name otherwise that line will come out without one.
  # Remember that -A with logging never write to terminals.
  my $temp=sprintf("%s", $options=~/t/ ? $cls : "\n");
  $temp.=sprintf("%s### RECORD %4d >>> $HostLC <<< ($seconds) ($date) ###\n",
	 $addrFlag ? "$Host " : '', $totalCounter, $lastSecs);

  printText($temp);
}

# Like printInterval, this is also used for terminal/socket output and therefore
# not something we need to worry about for logging!
sub printText
{
  my $text=shift;
  print $text    if !$addrFlag;

  # just like in writeData, we need to make sure each line preceed with host name.
  if ($addrFlag)
  {
    $text=~s/^(.*)$/$Host $1/mg;
    print $socket $text;
  }
}

# see if time to print header
sub printHeader
{
  return $options!~/H/ && 
	($options!~/h/ || $totalCounter==1 || ($totalCounter % $headerRepeat)==0) ? 1 : 0;
}

sub getHeader
{
  my $file=shift;
  my ($gzFlag, $header, $TEMP, $line);

  $gzFlag=$file=~/gz$/ ? 1 : 0;
  if ($gzFlag)
  {
    $TEMP=Compress::Zlib::gzopen($file, "rb") or logmsg("F", "Couldn't open '$file'");
  }
  else
  {
    open TEMP, "<$file" or logmsg("F", "Couldn't open '$file'");
  }

  $header="";
  while (1)
  {
    $TEMP->gzreadline($line)    if  $gzFlag;
    $line=<TEMP>                if !$gzFlag;

    last    if $line!~/^#/;
    $header.=$line;
  }
  close TEMP;
  print "*** Header For: $file ***\n$header"    if $debug & 16;
  return($header);
}

sub setKernelFlags
{
  my $kernel=shift;
  $kernel2_4=$kernel2_6=0;
  $kernel2_4=1    if $kernel=~/^2\.4/;
  $kernel2_6=1    if $kernel=~/^2\.6/;
}

sub incomplete
{
  my $type=shift;
  my $secs=shift;
  my $special=shift;
  my ($seconds, $ss, $mm, $hh, $mday, $mon, $year, $date, $time);

  $seconds=(split(/\./, $secs))[0];
  ($ss, $mm, $hh, $mday, $mon, $year)=localtime($seconds);
  $date=sprintf("%d%02d%02d", $year+1900, $mon+1, $mday);
  $time=sprintf("%02d:%02d:%02d", $hh, $mm, $ss);

  my $message=(!defined($special)) ? "Incomplete" : $special;
  my $where=($playback eq '') ? "on $date" : "in $playbackFile";
  logmsg("W", "$message data record skipped for $type data $where at $time");
}

# Handy for debugging
sub getTime
{
  my $seconds=shift;
  my ($ss, $mm, $hh, $mday, $mon, $year);
  ($ss, $mm, $hh, $mday, $mon, $year)=localtime($seconds);
  return(sprintf("%02d:%02d:%02d", $hh, $mm, $ss));
}

########################################
#      Brief Mode is VERY Special
########################################

sub briefFormatit
{
  my ($command, $pad, $i);
  my $line='';

  # We want to track elapsed time.  This is only looked at in interactive mode.
  $miniStart=$seconds    if !defined($miniStart) || $miniStart==0;

  if ($options!~/H/ && ($totalCounter % $headerRepeat)==1)
  {
    $pad=' ' x length($miniDateTime);
    $fill1=($Hyper eq '') ? "----" : "";
    $fill2=($Hyper eq '') ? "----" : "-";
    $line.="$cls#$pad";
    $line.="<----${fill1}CPU$Hyper$fill2---->"     if $subsys=~/c/;
    $line.="<-----------Memory---------->"         if $subsys=~/m/;
    $line.="<----slab---->"                        if $subsys=~/y/;
    $line.="<-----------Disks----------->"         if $subsys=~/d/;
    $line.="<-----------Network---------->"        if $subsys=~/n/;
    $line.="<------------TCP------------>"         if $subsys=~/t/;
    $line.="<------Sockets----->"                  if $subsys=~/s/;
    $line.="<--------------Elan------------>"      if $subsys=~/x/ && $NumXRails;
    $line.="<----------InfiniBand---------->"      if $subsys=~/x/ && ($NumHCAs || $NumHCAs+$NumXRails==0);
    $line.="<--NFS Svr Summary-->"                 if $subsys=~/f/ && $subOpts!~/C/;
    $line.="<--NFS Clt Summary-->"                 if $subsys=~/f/ && $subOpts=~/C/;
    $line.="<----NFS MetaOps---->"                 if $subsys=~/F/;
    $line.="<--------Lustre MDS-------->"          if $subsys=~/l/ && $reportMdsFlag;
    $line.="<--------Lustre OST------->"           if $subsys=~/l/ && $reportOstFlag;

    if ($subsys=~/l/ && $reportCltFlag)
    {
      $line.="<-------Lustre Client------>"                 if $subOpts!~/R/;
      $line.="<-------------Lustre Client-------------->"   if $subOpts=~/R/;
    }

    $line.="\n";
    $line.="#$miniDateTime";
    $line.="cpu sys inter  ctxsw "                 if $subsys=~/c/;
    $line.="free buff cach inac slab  map "        if $subsys=~/m/;
    $line.=" Alloc   Bytes "	 		   if $subsys=~/y/ && $slabinfoFlag;
    $line.=" InUse   Total "	 		   if $subsys=~/y/ && $slubinfoFlag;
    $line.="KBRead  Reads  KBWrit Writes "         if $subsys=~/[dp]/;
    $line.="netKBi pkt-in  netKBo pkt-out "        if $subsys=~/n/;
    $line.="PureAcks HPAcks   Loss FTrans "        if $subsys=~/t/;
    $line.="  Tcp  Udp  Raw Frag "                 if $subsys=~/s/;
    $line.="  KBin  pktIn  KBOut pktOut Errs "     if $subsys=~/x/ && $NumXRails;
    $line.="  KBin  pktIn  KBOut pktOut Errs "     if $subsys=~/x/ && ($NumHCAs || $NumHCAs+$NumXRails==0);
    $line.="  read  write  calls "                 if $subsys=~/f/;
    $line.="  meta commit retran "                 if $subsys=~/F/;
    $line.="mdsCls Getatt  Reint   sync "          if $subsys=~/l/ && $reportMdsFlag;
    $line.="KBRead  Reads KBWrit Writes "          if $subsys=~/l/ && $reportOstFlag;

    if ($subsys=~/l/ && $reportCltFlag)
    {
      $line.=" Reads KBRead Writes KBWrite";
      $line.="   Hits Misses"    if $subOpts=~/R/;
    }
    $line.="\n";
  }

  # leading space not needed for date/time
  $line.=sprintf(' ')    if !$miniDateFlag && !$miniTimeFlag;

  # First part always the same...
  $line.=sprintf("%s ", $datetime)    if $miniDateFlag || $miniTimeFlag;

  if ($subsys=~/c/)
  {
    $i=$NumCpus;
    $sysTot=$sysP[$i]+$irqP[$i]+$softP[$i]+$stealP[$i];
    $cpuTot=$userP[$i]+$niceP[$i]+$sysTot;
    $line.=sprintf("%3d %3d %5d %6d ",
        $cpuTot, $sysTot, $intrpt/$intSecs, $ctxt/$intSecs);
  }

  if ($subsys=~/m/)
  {
    $line.=sprintf("%4s %4s %4s %4s %4s %4s ",
        cvt($memFree,4,1,1),   cvt($memBuf,4,1,1), 
	cvt($memCached,4,1,1), cvt($inactive,4,1,1),
	cvt($memSlab,4,1,1),   cvt($memMap,4,1,1));
  }

  if ($subsys=~/y/)
  {
    if ($slabinfoFlag)
    {
      $line.=sprintf("%6s %7s ",
	cvt($slabSlabAllTotal,6), cvt($slabSlabAllTotalB,7,0,1));
    }
    else
    {
      $line.=sprintf("%6s %7s ",
	cvt($slabNumObjTot,7),  cvt($slabTotalTot,7,0,1));
    }
  }

  if ($subsys=~/d/)
  {
    $line.=sprintf("%6d %6d  %6d %6d ",
        $dskReadKBTot/$intSecs,  $dskReadTot/$intSecs,
        $dskWriteKBTot/$intSecs, $dskWriteTot/$intSecs);
  }

  # Network always the same
  if ($subsys=~/n/)
  {
    $line.=sprintf("%6d %6d  %6d  %6d ",
        $netEthRxKBTot/$intSecs, $netEthRxPktTot/$intSecs,
        $netEthTxKBTot/$intSecs, $netEthTxPktTot/$intSecs);
  }

  # Network always the same
  if ($subsys=~/t/)
  {
    $line.=sprintf("  %6d %6d %6d %6d ",
        $tcpValue[27]/$intSecs,  $tcpValue[28]/$intSecs,
        $tcpValue[40]/$intSecs,  $tcpValue[45]/$intSecs);
  }

  if ($subsys=~/s/)
  {
    $line.=sprintf(" %4d %4d %4d %4d ", 
	$sockUsed, $sockUdp, $sockRaw, $sockFrag);
  }

  # and so is elan
  if ($subsys=~/x/)
  {
    if ($NumXRails)
    {
      $elanErrors=$elanSendFailTot+$elanNeterrAtomicTot+$elanNeterrDmaTot;
      $line.=sprintf("%6d %6d %6d %6d %4d ",
          $elanRxKBTot/$intSecs, $elanRxTot/$intSecs,
          $elanTxKBTot/$intSecs, $elanTxTot/$intSecs,
	  $elanErrors/$intSecs);
    }
    if ($NumHCAs || $NumXRails+$NumHCAs==0)
    {
      $line.=sprintf("%6d %6d %6d %6d %4d ",
          $ibRxKBTot/$intSecs, $ibRxTot/$intSecs,
          $ibTxKBTot/$intSecs, $ibTxTot/$intSecs,
	  $ibErrorsTotTot);
    }
  }

  if ($subsys=~/f/)
  {
    $line.=sprintf("%6d %6d %6d ", 
	$nfsRead/$intSecs, $nfsWrite/$intSecs, $rpcCalls/$intSecs);
  }

  if ($subsys=~/F/)
  {
    $nfsMeta=$nfsLookup+$nfsAccess+$nfsSetattr+$nfsGetattr+$nfsReaddir+$nfsReaddirplus;
    $line.=sprintf("%6d %6d %6d ", 
	$nfsMeta/$intSecs, $nfsCommit/$intSecs, $rpcRetrans/$intSecs);
  }

  # MDS
  if ($subsys=~/l/ && $reportMdsFlag)
  {
    $line.=sprintf("%6d %6d %6d %6d ",
        $lustreMdsClose/$intSecs, $lustreMdsGetattr/$intSecs,
        $lustreMdsReint/$intSecs, $lustreMdsSync/$intSecs);
  }

  # OST
  if ($subsys=~/l/ && $reportOstFlag)
  {
    $line.=sprintf("%6d %6d %6d %6d ",
          $lustreReadKBytesTot/$intSecs,  $lustreReadOpsTot/$intSecs,
          $lustreWriteKBytesTot/$intSecs, $lustreWriteOpsTot/$intSecs);
  }

  #Lustre Client
  if ($subsys=~/l/ && $reportCltFlag)
  {
    # Add in cache hits/misses if -OR
    $line.=sprintf("%6d %6d %6d  %6d", 
	$lustreCltReadTot/$intSecs,  $lustreCltReadKBTot/$intSecs,
        $lustreCltWriteTot/$intSecs, $lustreCltWriteKBTot/$intSecs);
    $line.=sprintf(" %6d %6d", $lustreCltRAHitsTot, $lustreCltRAMissesTot)
		if ($subOpts=~/R/)
  }
  $line.="\n";

  #   S p e c i a l    ' h o t '    K e y    P r o c e s s i n g

  # First time through when an attached terminal
  if ($termFlag && !defined($mini1select))
  {
    $mini1select=new IO::Select(STDIN);
    resetMini1Counters();
    `stty -echo`    if !$PcFlag;
  }

  # See if user entered a command.  If not, @ready will never be
  # non-zero so the 'if' below will never fire.
  @ready=$mini1select->can_read(0)    if $termFlag;
  if (scalar(@ready))
  {
    $command=<STDIN>;
    $resetType='T';
    $resetType=$command    if $command=~/a|t|z/i;
    printMini1Counters($resetType);
    resetMini1Counters()    if $resetType=~/Z/i;
  }

  # This is a little weird.  Since we return the output line and don't actually 
  # print it yet, we don't want to include this interval's numbers in the
  # subtotal which actually prints BEFORE this intervald does.  So count them now.
  $miniInstances++;
  countMini1Counters();

  return($line);
}

sub resetMini1Counters
{
  # talk about a mouthful!
  $miniStart=0;
  $miniInstances=0;
  $cpuTOT=$sysPTOT=$intrptTOT=$ctxtTOT=0;
  $memFreeTOT=$memBufTOT=$memCachedTOT=$inactiveTOT=$memSlabTOT=$memMapTOT=0;
  $slabSlabAllTotalTOT=$slabSlabAllTotalBTOT=0;
  $dskReadKBTOT=$dskReadTOT=$dskWriteKBTOT=$dskWriteTOT=0;
  $netEthRxKBTOT=$netEthRxPktTOT=$netEthTxKBTOT=$netEthTxPktTOT=0;
  $tcpPAckTOT=$tcpHPAckTOT=$tcpLossTOT=$tcpFTransTOT=0;
  $sockUsedTOT=$sockUdpTOT=$sockRawTOT=$sockFragTOT=0;
  $elanRxKBTOT=$elanRxTOT=$elanTxKBTOT=$elanTxTOT=$elanErrorsTOT=0;
  $ibRxKBTOT=$ibRxTOT=$ibTxKBTOT=$ibTxTOT=$ibErrorsTOT=0;
  $nfsReadTOT=$nfsWriteTOT=$rpcCallsTOT=$nfsMetaTOT=$nfsCommitTOT=$rpcRetransTOT=0;
  $lustreMdsCloseTOT=$lustreMdsGetattrTOT=$lustreMdsReintTOT=$lustreMdsSyncTOT=0;
  $lustreReadKBytesTOT=$lustreReadOpsTOT=$lustreWriteKBytesTOT=$lustreWriteOpsTOT=0;
  $lustreCltReadTOT=$lustreCltReadKBTOT=$lustreCltWriteTOT=$lustreCltWriteKBTOT=0;
  $lustreCltRAHitsTOT=$lustreCltRAMissesTOT=0;
  for (my $i=0; $i<$numBrwBuckets; $i++)
  {
    $lustreBufReadTOT[$i]=$lustreBufWriteTOT[$i]=0;
  }
}

sub countMini1Counters
{
  my $i=$NumCpus;
  $cpuTOT+=   $userP[$i]+$niceP[$i]+$sysP[$i];
  $sysPTOT+=  $sysP[$i];
  $intrptTOT+=$intrpt;
  $ctxtTOT+=  $ctxt;
  
  $memFreeTOT+=  $memFree;
  $memBufTOT+=   $memBuf;
  $memCachedTOT+=$memCached;
  $inactiveTOT+= $inactive;
  $memSlabTOT+=  $memSlab;
  $memMapTOT+=   $memMap;

  $slabSlabAllTotalTOT+= $slabSlabAllTotal;
  $slabSlabAllTotalBTOT+=$slabSlabAllTotalB;

  $dskReadKBTOT+=  $dskReadKBTot;
  $dskReadTOT+=    $dskReadTot;
  $dskWriteKBTOT+= $dskWriteKBTot;
  $dskWriteTOT+=   $dskWriteTot;

  $netEthRxKBTOT+= $netEthRxKBTot;
  $netEthRxPktTOT+=$netEthRxPktTot;
  $netEthTxKBTOT+= $netEthTxKBTot;
  $netEthTxPktTOT+=$netEthTxPktTot;

  $tcpPAckTOT+=    $tcpValue[27];
  $tcpHPAckTOT+=   $tcpValue[28];
  $tcpLossTOT+=    $tcpValue[40];
  $tcpFTransTOT+=  $tcpValue[45];

  $sockUsedTOT+=   $sockUsed;
  $sockUdpTOT+=	   $sockUdp;
  $sockRawTOT+=    $sockRaw;
  $sockFragTOT+=   $sockFrag;

  $elanRxKBTOT+=   $elanRxKBTot;
  $elanRxTOT+=     $elanRxTot;
  $elanTxKBTOT+=   $elanTxKBTot;
  $elanTxTOT+=     $elanTxTot;
  $elanErrorsTOT+= $elanErrors;

  $ibRxKBTOT+=     $ibRxKBTot;
  $ibRxTOT+=       $ibRxTot;
  $ibTxKBTOT+=     $ibTxKBTot;
  $ibTxTOT+=       $ibTxTot;
  $ibErrorsTOT+=   $ibErrorsTotTot;

  $nfsReadTOT+=    $nfsRead;
  $nfsWriteTOT+=   $nfsWrite;
  $rpcCallsTOT+=   $rpcCalls;

  $nfsMetaTOT+=    $nfsMeta;
  $nfsCommitTOT+=  $nfsCommit;
  $rpcRetransTOT+= $rpcRetrans;

  if ($NumMds)
  {
    $lustreMdsCloseTOT+=  $lustreMdsClose;
    $lustreMdsGetattrTOT+=$lustreMdsGetattr;
    $lustreMdsReintTOT+=  $lustreMdsReint;
    $lustreMdsSyncTOT+=   $lustreMdsSync;
  }

  if ($NumOst)
  {
    $lustreReadKBytesTOT+= $lustreReadKBytesTot;
    $lustreReadOpsTOT+=    $lustreReadOpsTot;
    $lustreWriteKBytesTOT+=$lustreWriteKBytesTot;
    $lustreWriteOpsTOT+=   $lustreWriteOpsTot;
  }

  if ($reportCltFlag)
  {
    $lustreCltReadTOT+=   $lustreCltReadTot;
    $lustreCltReadKBTOT+= $lustreCltReadKBTot;
    $lustreCltWriteTOT+=  $lustreCltWriteTot;
    $lustreCltWriteKBTOT+=$lustreCltWriteKBTot;

    $lustreCltRAHitsTOT+=  $lustreCltRAHitsTot;
    $lustreCltRAMissesTOT+=$lustreCltRAMissesTot;
  }
}

sub printMini1Counters
{
  my $type=shift;
  my $i;

  # Average only non-1 for averages to make math easy.
  $aveSecs=1;
  if ($type=~/a/i)
  {
    $aveSecs=($playback eq '') ? $seconds-$miniStart+1 : $elapsedSecs;
    $datetime=' ' x length($datetime);
  }

  chomp $type;
  printf "%s", $datetime     if $miniDateFlag || $miniTimeFlag;
  printf "%s", uc($type);

  printf "%3d %3d %5d %6d ",
	$cpuTOT/$miniInstances,    $sysPTOT/$miniInstances, 
	$intrptTOT/$miniInstances, $ctxtTOT/$miniInstances
  	          if $subsys=~/c/;

  printf "%4s %4s %4s %4s %4s %4s ",
        cvt($memFreeTOT/$miniInstances,4,1,1),   
	cvt($memBufTOT/$miniInstances,4,1,1), 
	cvt($memCachedTOT/$miniInstances,4,1,1), 
	cvt($inactiveTOT/$miniInstances,4,1,1),
	cvt($memSlabTOT/$miniInstances,4,1,1),
	cvt($memMapTOT/$miniInstances,4,1,1)
		  if $subsys=~/m/;

  printf "%6s %7s ", 
	cvt($slabSlabAllTotalTOT/$miniInstances,6,0,1), 
	cvt($slabSlabAllTotalBTOT/$miniInstances,7,0,1)
		  if $subsys=~/y/;

  if ($subsys=~/d/)
  { 
    printf "%6s %6s  %6s %6s ", 
	cvt($dskReadKBTOT/$aveSecs,6,0,1),  cvt($dskReadTOT/$aveSecs,6), 
	cvt($dskWriteKBTOT/$aveSecs,6,0,1), cvt($dskWriteTOT/$aveSecs,6);
   }

  printf "%6s %6s  %6s  %6s ", 
	cvt($netEthRxKBTOT/$aveSecs,6,0,1), cvt($netEthRxPktTOT/$aveSecs,6), 
	cvt($netEthTxKBTOT/$aveSecs,6,0,1), cvt($netEthTxPktTOT/$aveSecs,6)
	 	 if $subsys=~/n/;

  printf "  %6s %6s %6s %6s ",
        cvt($tcpPAckTOT/$aveSecs,6), cvt($tcpHPAckTOT/$aveSecs,6),
        cvt($tcpLossTOT/$aveSecs,6), cvt($tcpFTransTOT/$aveSecs,6)
		  if $subsys=~/t/;

  printf " %4d %4d %4d %4d ",
	int($sockUsedTOT/$miniInstances), int($sockUdpTOT/$miniInstances), 
	int($sockRawTOT/$miniInstances),  int($sockFragTOT/$miniInstances)
                  if $subsys=~/s/;

  printf "%6s %6s %6s %6s %6s ", 
	cvt($elanRxKBTOT/$aveSecs,6), cvt($elanRxTOT/$aveSecs,6), 
        cvt($elanTxKBTOT/$aveSecs,6), cvt($elanTxTOT/$aveSecs,6),
        cvt($elanErrorsTOT/$aveSecs,6)
		  if $subsys=~/x/ && $NumXRails;

  printf "%6s %6s %6s %6s %4s ", 
	cvt($ibRxKBTOT/$aveSecs,6), cvt($ibRxTOT/$aveSecs,6), 
        cvt($ibTxKBTOT/$aveSecs,6), cvt($ibTxTOT/$aveSecs,6),
        cvt($ibErrorsTOT,4)
		  if $subsys=~/x/ && $NumHCAs;

  printf "%6s %6s %6s ", 
	cvt($nfsReadTOT/$aveSecs,6), cvt($nfsWriteTOT/$aveSecs,6), 
        cvt($rpcCallsTOT/$aveSecs,6)
	          if $subsys=~/f/;

  printf "%6s %6s %6s ",
        cvt($nfsMetaTOT/$aveSecs,6), cvt($nfsCommitTOT/$aveSecs,6),
        cvt($rpcRetransTOT/$aveSecs,6)
  	          if $subsys=~/F/;

  printf "%6s %6s %6s %6s ",
        cvt($lustreMdsCloseTOT/$aveSecs,6), cvt($lustreMdsGetattrTOT/$aveSecs,6), 
	cvt($lustreMdsReintTOT/$aveSecs,6), cvt($lustreMdsSyncTOT/$aveSecs,6)
		  if $subsys=~/l/ && $reportMdsFlag;

  if ($subsys=~/l/ && $reportOstFlag)
  {
    printf "%6s %6s %6s %6s ",
         cvt($lustreReadKBytesTOT/$aveSecs,6,0,1),  cvt($lustreReadOpsTOT/$aveSecs,6),
	 cvt($lustreWriteKBytesTOT/$aveSecs,6,0,1), cvt($lustreWriteOpsTOT/$aveSecs,6);
  }

  if ($subsys=~/l/ && $reportCltFlag)
  {
    printf "%6s %6s %6s  %6s", 
	cvt($lustreCltReadTOT/$aveSecs,6),  cvt($lustreCltReadKBTOT/$aveSecs,6,0,1), 
	cvt($lustreCltWriteTOT/$aveSecs,6), cvt($lustreCltWriteKBTOT/$aveSecs,6,0,1);
    printf " %6s %6s", 
	cvt($lustreCltRAHitsTOT/$aveSecs,6),cvt($lustreCltRAMissesTOT/$aveSecs,6)
	    if $subOpts=~/R/;
 }
  print "\n";
}

####################################################
#    T a s k    P r o c e s s i n g    S u p p o r t
####################################################

sub nextAvailProcIndex
{
  my $next;

  if (scalar(@procIndexesFree)>0)
  { $next=pop @procIndexesFree; }
  else
  { $next=$procNextIndex++; }

  printf "### Index allocated: $next NextIndex: $procNextIndex IndexesFree: %d\n",
	scalar(@procIndexesFree)    if $debug & 256;
  return($next);
}

# If we're not processing by pid-only, the processes we're reporting on come
# and go.  Therefore right before we print we need to see if a process we 
# were reporting on disappeared by noticing its pid went away and therefore 
# need to remove it from the $procIndexes{} hash.  Is there a better/more 
# efficient way to do this?  If so, fix 'cleanStalePids()' too.
sub cleanStaleTasks
{
  my ($removeFlag, %indexesTemp, $pid);

  if ($debug & 512)
  {
    print "### CleanStaleTasks()\n";
    foreach $pid (sort keys %procSeen)
    { print "### PIDPROC: $pid\n"; }
  }

  # make a list of only those pids we've seen during last cycle
  $removeFlag=0;
  foreach $pid (sort keys %procIndexes)
  {
    if (defined($procSeen{$pid}))
    {
      $indexesTemp{$pid}=$procIndexes{$pid};
      print "### indexesTemp[$pid] set to $indexesTemp{$pid}\n"
	if $debug & 256;
    }
    else
    {
      push @procIndexesFree, $procIndexes{$pid};
      $removeFlag=1; 
      print "### added $pid with index of $procIndexes{$pid} to free list\n"
	if $debug & 256;
    }
  }

  # only need to do a swap if we need to remove a pid.
  if ($removeFlag)
  {
    undef %procIndexes;
    %procIndexes=%indexesTemp;
    if ($debug & 512)
    {
      print "### Indexes Swapped!  NEW procIndexes{}\n";
      foreach $key (sort keys %procIndexes)
      { print "procIndexes{$key}=$procIndexes{$key}\n"; }
    }
  }
  undef %procSeen;
}

# This output only goes to the .prc file
sub printPlotProc
{
  my $date=shift;
  my $time=shift;
  my ($procHeaders, $procPlot, $pid, $i);

  $procHeaders='';
  if (!$headersPrintedProc)
  {
    $procHeaders=$commonHeader    if $logToFileFlag;
    $procHeaders.=(!$utcFlag) ? "#Date${SEP}Time" : '#UTC';;
    $procHeaders.="${SEP}PID${SEP}User${SEP}PR${SEP}PPID${SEP}S${SEP}VmSize${SEP}";
    $procHeaders.="VmLck${SEP}VmRSS${SEP}VmData${SEP}VmStk${SEP}VmExe${SEP}VmLib${SEP}";
    $procHeaders.="SysT${SEP}UsrT${SEP}AccumT${SEP}";
    $procHeaders.="RKB${SEP}WKB${SEP}RKBC${SEP}WKBC${SEP}RSYS${SEP}WSYS${SEP}CNCL${SEP}";
    $procHeaders.="MajF${SEP}MinF${SEP}Command\n";
    $headersPrintedProc=1;
  }

  $procPlot=$procHeaders;
  foreach $pid (sort keys %procIndexes)
  {
    $i=$procIndexes{$pid};
    next    if (!defined($procSTimeTot[$i]));

    # Handle -oF
    if ($options=~/F/)
    {
      $majFlt=$procMajFltTot[$i];
      $minFlt=$procMinFltTot[$i];
    }
    else
    {
      $majFlt=$procMajFlt[$i]/$interval2Secs;
      $minFlt=$procMinFlt[$i]/$interval2Secs;
    }

    my $datetime=(!$utcFlag) ? "$date$SEP$time": time;
    $datetime.=".$usecs"    if $options=~/m/;

    # Username comes from translation hash OR we just print the UID
    $procPlot.=sprintf("%s${SEP}%d${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%d${SEP}%d${SEP}%d${SEP}%d${SEP}%d${SEP}%d${SEP}%d${SEP}%s${SEP}%s${SEP}%s",
          $datetime, $procPid[$i], $procUser[$i],  $procPri[$i], 
	  $procPpid[$i],  $procState[$i],  
	  defined($procVmSize[$i]) ? $procVmSize[$i] : 0, 
	  defined($procVmLck[$i])  ? $procVmLck[$i]  : 0,
	  defined($procVmRSS[$i])  ? $procVmRSS[$i]  : 0,
	  defined($procVmData[$i]) ? $procVmData[$i] : 0,
	  defined($procVmStk[$i])  ? $procVmStk[$i]  : 0,  
	  defined($procVmExe[$i])  ? $procVmExe[$i]  : 0,
	  defined($procVmLib[$i])  ? $procVmLib[$i]  : 0,
	  cvtT1($procSTime[$i],1), cvtT1($procUTime[$i],1), 
	  cvtT2($procSTimeTot[$i]+$procUTimeTot[$i],1),
	  defined($procRKB[$i])    ? $procRKB[$i]/$interval2Secs  : 0,
	  defined($procWKB[$i])    ? $procWKB[$i]/$interval2Secs  : 0,
	  defined($procRKBC[$i])   ? $procRKBC[$i]/$interval2Secs : 0,
	  defined($procWKBC[$i])   ? $procWKBC[$i]/$interval2Secs : 0,
	  defined($procRSys[$i])   ? $procRSys[$i]/$interval2Secs : 0,
	  defined($procWSys[$i])   ? $procWSys[$i]/$interval2Secs : 0,
	  defined($procCKB[$i])    ? $procCKB[$i]/$interval2Secs  : 0,
	  cvt($majFlt), cvt($minFlt),
	  defined($procCmd[$i])    ? $procCmd[$i] : $procName[$i]);

    # This is a little messy (sorry about that).  The way writeData works is that
    # on writeData(0) calls, it builds up a string in $oneline which can be appended
    # to the current string (for displaying multiple subsystems in plot format on
    # the terminal and the final call writes it out.  In order for all the paths
    # to work with sockets, etc we need to do it this way.  And since writeData takes
    # care of \n be sure to leave OFF each line being written.
    $oneline='';
    writeData(0, '', \$procPlot, PRC, $ZPRC, 'proc', \$oneline);
    writeData(1, '', undef, $LOG, undef, undef, \$oneline)
        if !$logToFileFlag || $addrFlag;
    $procPlot='';
  }
}

# like printProc, this only goes to .slb and we don't care about --logtoo
sub printPlotSlab
{
  my $date=shift;
  my $time=shift;
  my ($slabHeaders, $slabPlot);

  $slabHeaders='';
  if (!$headersPrintedSlab)
  {
    $slabHeaders=$commonHeader    if $logToFileFlag;
    $slabHeaders.=$slubHeader     if $logToFileFlag && $slubinfoFlag;
    $slabHeaders.=(!$utcFlag) ? "#Date${SEP}Time" : '#UTC';
    if ($slabinfoFlag)
    {
      $slabHeaders.="${SEP}SlabName${SEP}ObjInUse${SEP}ObjInUseB${SEP}ObjAll${SEP}ObjAllB${SEP}";
      $slabHeaders.="SlabInUse${SEP}SlabInUseB${SEP}SlabAll${SEP}SlabAllB\n";
    }
    else
    {
      $slabHeaders.="${SEP}SlabName${SEP}ObjSize${SEP}ObjPerSlab${SEP}ObjInUse${SEP}ObjAvail${SEP}";
      $slabHeaders.="SlabSize${SEP}SlabNumber${SEP}MemUsed${SEP}MemTotal\n";
    }
    $headersPrintedSlab=1;
  }

  my $datetime=(!$utcFlag) ? "$date$SEP$time": time;
  $datetime.=".$usecs"    if $options=~/m/;
  $slabPlot=$slabHeaders;

  #    O l d    S l a b    F o r m a t

  if ($slabinfoFlag)
  {
    for (my $i=0; $i<$NumSlabs; $i++)
    {
      # Skip filtered data
      next    if ($options=~/s/ && $slabSlabAllTot[$i]==0) ||
                 ($options=~/S/ && $slabSlabAct[$i]==0 && $slabSlabAll[$i]==0);

      $slabPlot.=sprintf("%s$SEP%s$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d\n",
     	   $datetime, $slabName[$i],
	   $slabObjActTot[$i],  $slabObjActTotB[$i], $slabObjAllTot[$i],  $slabObjAllTotB[$i],
           $slabSlabActTot[$i], $slabSlabActTotB[$i],$slabSlabAllTot[$i], $slabSlabAllTotB[$i]);
    }
  }

  #    N e w    S l a b    F o r m a t

  else
  {
    foreach my $first (sort keys %slabfirst)
    {
      # This is all pretty much lifted from 'Slab Detail' reporting
      my $slab=$slabfirst{$first};
      my $numObjects=$slabdata{$slab}->{objects};
      my $numSlabs=  $slabdata{$slab}->{slabs};

      next    if ($options=~/s/ && $slabdata{$slab}->{objects}==0) ||
                 ($options=~/S/ && $slabdata{$slab}->{lastobj}==$numObjects &&
                                   $slabdata{$slab}->{lastslabs}==$numSlabs);

      $slabPlot.=sprintf("$datetime$SEP%s$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d$SEP%d\n",
            $first,      $slabdata{$slab}->{slabsize},  $slabdata{$slab}->{objper},
            $numObjects, $slabdata{$slab}->{avail},     ($PageSize<<$slabdata{$slab}->{order})/1024,
            $numSlabs,   $slabdata{$slab}->{used}/1024, $slabdata{$slab}->{total}/1024);

      # So we can tell when something changes
      $slabdata{$slab}->{lastobj}=  $numObjects;
      $slabdata{$slab}->{lastslabs}=$numSlabs;
    }
  }

  # See printPlotProc() for details on this...
  # Also note we're printing the whole thing in one call vs 1 call/line and we
  # only want to print when there's data since filtering can result in blank
  # lines.  Finally, since writeData() appends a find \n, we need to strip it.
  if ($slabPlot ne '')
  {
    $oneline='';
    $slabPlot=~s/\n$//;
    writeData(0, '', \$slabPlot, SLB, $ZSLB, 'slb', \$oneline);
    writeData(1, '', undef, $LOG, undef, undef, \$oneline)
        if !$logToFileFlag || $addrFlag;
  }
}

sub elanCheck
{
  my $saveRails=$NumXRails;

  $NumXRails=0;
  if (!-e "/proc/qsnet")
  {
    logmsg('W', "no interconnect data found (/proc/qsnet missing)")
	if $inactiveElanFlag==0;
    $inactiveElanFlag=1;
  }
  else
  {
    $NumXRails++    if -e "/proc/qsnet/ep/rail0";
    $NumXRails++    if -e "/proc/qsnet/ep/rail1";

    # Now that I changed from using `cat` to cat(), let's just do
    # this each time.
    if ($NumXRails)
    {
      $XType='Elan';
      $XVersion=cat('/proc/qsnet/ep/version');
      chomp $XVersion;
    }
    else
    {
      logmsg('W', "/proc/qsnet exists but no rail stats found.  is the driver loaded?")
	  if $inactiveElanFlag==0;
      $inactiveElanFlag=1;
    }
  }

  print "ELAN Change -- OldRails: $saveRails  NewRails: $NumXRails\n"
        if $debug & 2 && $NumXRails ne $saveRails;

  return ($NumXRails ne $saveRails) ? 1 : 0;
}

sub ibCheck
{
  my $saveHCANames=$HCANames;
  my $activePorts=0;
  my ($line, @lines, $port);

  # Just because we have hardware doesn't mean any drivers installed and
  # the assumption for now is that's the case if you can't find vstat.
  # Since VStat can be a list, reset to the first that is found (if any)
  $NumHCAs=0;
  my $found=0;
  foreach my $temp (split(/:/, $VStat))
  {
    if (-e $temp)
    {
      $found=1;
      $VStat=$temp;
      last;
    }
  }

  # This error can only happen when NOT open fabric
  if (!-e $SysIB && !$found)
  {
    logmsg('E', "Found HCA(s) but no software OR monitoring disabled in collectl.conf")
        if $inactiveIBFlag==0;
    $mellanoxFlag=0;
    $inactiveIBFlag=1;
    return(0);
  }

  # We need the names of the interfaces and port info, but it depends on the
  # type of IB we're dealing with.  In the case of 'vib' we get them via 'vtstat'
  # and in the case of ofed via '/sys'.  However, in very rare cases someone might
  # have both stacks installed so just because we find 'vstat' doesn't mean vib is
  # loaded.
  my ($maxPorts, $numPorts)=(0,0);
  $HCANames='';
  if (-e $VStat)
  {
    @lines=`$VStat`;
    foreach $line (@lines)
    {
      if ($line=~/hca_id=(.+)/)
      {
	# We need to track max ports across all HCAs.  Most likely this
        # is a contant.
        $maxPorts=$numPorts    if $numPorts>$maxPorts;
        $numPorts=0;

        $NumHCAs++;
        $HCAName[$NumHCAs-1]=$1;
        $HCAPorts[$NumHCAs-1]=0;  # none active yet
        $HCANames.=" $1";
      }
      elsif ($line=~/port=(\d+)/)
      {
        $port=$1;
        $numPorts++;
      }
      elsif ($line=~/port_state=(.+)/)
      {
        $portState=($1 eq 'PORT_ACTIVE') ? 1 : 0;
        $HCAPorts[$NumHCAs-1][$port]=$portState;
        if ($portState)
        {
	  print "  VIB Port: $port\n"    if $debug & 1;
          $HCANames.=":$port";
          $activePorts++;
        }
      }
    $maxPorts=$numPorts    if $numPorts>$maxPorts;
    }

    # Only if we found any HCAs (since 'vib' may not actually be loaded...)
    $VoltaireStats=(-e '/proc/voltaire/adaptor-mlx/stats') ?
	  '/proc/voltaire/adaptor-mlx/stats' : '/proc/voltaire/ib0/stats'
		if $NumHCAs;
  }

  # To get here, either no 'vib' OR 'vib' is there but not loaded
  if ($NumHCAs==0)
  {
    my (@ports, $state, $file, $lid);
    @lines=ls($SysIB);
    foreach $line (@lines)
    {
      $line=~/(.*?)(\d+)/;
      $devname=$1;
      $devnum=$2;

      # While this should work for any ofed compliant adaptor, doing it this
      # way at least makes it more explicit which ones have been found to work.
      if ($devname=~/mthca|mlx4_/)
      {
        $HCAName[$NumHCAs]=$devname;
        $HCAPorts[$NumHCAs]=0;  # none active yet
        $HCANames.=" $devname";
	$file=$SysIB;
	$file.="/$devname";
	$file.=$devnum;
	$file.="/ports";

        @ports=ls($file);
	$maxPorts=scalar(@ports)    if scalar(@ports)>$maxPorts;
        foreach $port (@ports)
        {
	  $port=~/(\d+)/;
	  $port=$1;
	  $state=cat("$file/$1/state");
          $state=~/.*: *(.+)/;
          $portState=($1 eq 'ACTIVE') ? 1 : 0;
          $HCAPorts[$NumHCAs][$port]=$portState;
	  chomp($lid=cat("$file/$port/lid"));
          $HCALids[$NumHCAs][$port]=$lid;
	  if ($portState)
          {
	    print "  OFED Port: $port  LID: $lid\n"    if $debug & 1;
            $HCANames.=":$port";
            $activePorts++;
           }
        }
      }
      $NumHCAs++;
    }
  }
  $HCANames=~s/^ //;

  # Now we need to know port states for header.
  $HCAPortStates='';
  for ($i=0; $i<$NumHCAs; $i++)
  {
    for (my $j=1; $j<=scalar($maxPorts); $j++)
    {
      # The expectation is the number of ports is contant on all HCAs
      # but just is case they're not, set extras to 0.
      $HCAPorts[$i][$j]=0    if !defined($HCAPorts[$i][$j]);
      $HCAPortStates.=$HCAPorts[$i][$j];
    }
    $HCAPortStates.=':';
  }
  $HCAPortStates=~s/:$//;

  # only report inactive status once per day OR after something changed
  if ($activePorts==0)
  {
    logmsg('E', "Found $NumHCAs HCA(s) but none had any active ports")
        if $inactiveIBFlag==0;
    $inactiveIBFlag=1;
  }

  # The names include active ports too so changes can be detected.
  $changeFlag=($HCANames ne $saveHCANames) ? 1 : 0;
  print "IB Change -- OldHCAs: $saveHCANames  NewHCAs: $HCANames\n"
        if $debug & 2 && $HCANames ne $saveHCANames;

  return ($activePorts && $HCANames ne $saveHCANames) ? 1 : 0;
}

sub lustreCheckClt
{
  # don't bother checking if specific services were specified and not this one
  return 0    if $lustreSvcs ne '' && $lustreSvcs!~/c/;

  my ($saveFS, $saveOsts, $saveInfo, @lustreFS, @lustreDirs);
  my ($dir, $dirname, $inactiveFlag);

  # We're saving the info because as unlikely as it is, if the ost or fs state
  # changes without their numbers changing, we need to know!
  $saveFS=   $NumLustreFS;
  $saveOsts= $NumLustreCltOsts;
  $saveInfo= $lustreCltInfo;

  undef @lustreCltDirs;
  undef @lustreCltFS;
  undef @lustreCltFSCommon;
  undef @lustreCltOsts;
  undef @lustreCltOstFS;
  undef @lustreCltOstDirs;

  #    G e t    F i l e s y s t e m    N a m e s

  $FSWidth=0;
  @lustreFS=glob("/proc/fs/lustre/llite/*");
  $lustreCltInfo='';
  foreach my $dir (@lustreFS)
  {
    # in newer versions of lustre, the fs name was dropped from uuid, so look here instead
    # which does exist in earlier versions too, but we didn't look there sooner because
    # uuid is still used in other cases and I wanted to be consistent.
    my $commonName=cat("$dir/lov/common_name");
    chomp $commonName;
    my $fsName=(split(/-/, $commonName))[0];

    # we use the dirname for finding 'stats' and fsname for printing.
    # we may need the common name to make osts back to filesystems
    my $dirname=basename($dir);
    push @lustreCltDirs,     $dirname;
    push @lustreCltFS,       $fsName;
    push @lustreCltFSCommon, $commonName;

    $lustreCltInfo.="$fsName: ";
    $FSWidth=length($fsName)    if $FSWidth<length($fsName);
    $CltFlag=1;
  }
  $FSWidth++;
  $NumLustreFS=scalar(@lustreCltFS);

  # if the number of FS grew, we need to init more variables!
  initLustre('c', $saveFS, $NumLustreFS)    if $NumLustreFS>$saveFS;

  #    O n l y    F o r    ' L L '    o r    - O B    G e t    O S T    N a m e s

  undef %lustreCltOstMappings;
  $inactiveFlag=0;
  $NumLustreCltOsts='-';    # only meaningful for -sLL
  if ($subsys=~/LL/ || $subOpts=~/B/)
  {
    # we first need to get a list of all the OST uuids for all the filesystems, noting
    # the 1 passed to cat() tells it to read until EOF
    foreach my $commonName (@lustreCltFSCommon)
    {
      my $fsName=(split(/-/, $commonName))[0];
      my $obds=cat("/proc/fs/lustre/lov/$commonName/target_obd", 1);
      foreach my $obd (split(/\n/, $obds))
      {
        my ($uuid, $state)=(split(/\s+/, $obd))[1,2];
        next    if $state ne 'ACTIVE';
	$lustreCltOstMappings{$uuid}=$fsName;
      }
    }

    $lustreCltInfo='';      # reset by adding in OSTs
    $NumLustreCltOsts=0;
    @lustreDirs=glob("/proc/fs/lustre/osc/*");
    foreach $dir (@lustreDirs)
    {
      next    if $dir!~/\d+_MNT/;

      # if ost closed (this happens when new filesystems get created), ignore it.
      my ($uuid, $state)=split(/\s+/, cat("$dir/ost_server_uuid"));
      next    if $state eq 'CLOSED';

      # Our uuid looks something like 'ibsfs-ost15_UUID' so we need to split on 
      # both - and _ pulling out the middle piece.  The filesystem name comes
      # from our mapping hash
      $ostName=(split(/[-_]/, $uuid))[1];
      $fsName=$lustreCltOstMappings{$uuid};

      $OstWidth=length($ostName)    if $OstWidth<length($ostName);

      $lustreCltInfo.="$fsName:$ostName ";
      $lustreCltOsts[$NumLustreCltOsts]=$ostName;
      $lustreCltOstFS[$NumLustreCltOsts]=$fsName;
      $lustreCltOstDirs[$NumLustreCltOsts]=$dir;
      $NumLustreCltOsts++;
    }
    $inactiveOstFlag=$inactiveFlag;
    $OstWidth=3    if $OstWidth<3;

    # If osts grew, need to init for new ones.
    initLustre('c2', $saveOsts, $NumLustreCltOsts)    if $NumLustreCltOsts>$saveOsts;
  }
  $lustreCltInfo=~s/ $//;

  print "CLT Change -- OldInfo: $saveInfo  New: $lustreCltInfo\n"
        if $debug & 2 && $lustreCltInfo ne $saveInfo;
  return ($lustreCltInfo ne $saveInfo) ? 1 : 0;
}

sub lustreCheckMds
{
  # don't bother checking if specific services were specified and not this one
  return 0    if $lustreSvcs ne '' && $lustreSvcs!~/m/;

  # if this wasn't an MDS and still isn't, nothing has changed.
  return 0    if !$NumMds && !-e "/proc/fs/lustre/mdt/MDT/mds/stats";

  my ($saveMdsNames, @mdsDirs, $mdsName);
  $saveMdsNames=$MdsNames;

  $MdsNames='';
  $NumMds=$MdsFlag=0;
  @mdsDirs=glob("/proc/fs/lustre/mds/*");
  foreach $mdsName (@mdsDirs)
  {
    next    if $mdsName=~/num_refs/;
    $mdsName=basename($mdsName);
    $MdsNames.="$mdsName ";
    $NumMds++;
    $MdsFlag=1;    # for consistency with CltFlag and OstFlag
  }
  $MdsNames=~s/ $//;

  print "MDS Change -- Old:    $saveMdsNames  New: $MdsNames\n"
        if $debug & 2 && $MdsNames ne $saveMdsNames;
  return ($MdsNames ne $saveMdsNames) ? 1 : 0;
}

sub lustreCheckOst
{ 
  # don't bother checking if specific services were specified and not this one
  return 0    if $lustreSvcs ne '' && $lustreSvcs!~/o/;

  # if this wasn't an OST and still isn't, nothing has changed.
  return 0    if !$NumOst && !-e "/proc/fs/lustre/obdfilter";

  my ($saveOst, $saveOstNames, @ostFiles, $file, $ostName, $subdir);
  $saveOst=$NumOst;
  $saveOstNames=$OstNames;

  undef @lustreOstSubdirs;

  # check for OST files
  $OstNames='';
  $NumOst=$OstFlag=0;
  @ostFiles=glob("/proc/fs/lustre/obdfilter/*/stats");
  foreach $file (@ostFiles)
  {
    $file=~m[/proc/fs/lustre/obdfilter/(.*)/stats];
    $subdir=$1;
    push @lustreOstSubdirs, $subdir;

    $temp=cat("/proc/fs/lustre/obdfilter/$subdir/uuid");
    $ostName=transLustreUUID($temp);
    $OstWidth=length($ostName)    if $OstWidth<length($ostName);

    $lustreOsts[$NumOst]=$ostName;
    $OstNames.="$ostName ";
    $NumOst++;
    $OstFlag=1;   # for consistency with CltFlag and MdsFlag
  }
  $OstNames=~s/ $//;
  $OstWidth=3    if $OstWidth<3;
  initLustre('o', $saveOst, $NumOst)    if $NumOst>$saveOst;

  print "OST Change -- Old:    $saveOstNames  New: $OstNames\n"
	if $debug & 2 && $OstNames ne $saveOstNames;
  return ($OstNames ne $saveOstNames) ? 1 : 0;
}

sub transLustreUUID
{
  my $name=shift;
  my $hostRoot;

  # This handles names like OST_Lustre9_2_UUID or OST_Lustre9_UUID or in
  # the case of SFS something like ost123_UUID, changing them to just 0,9
  # or ost123.
  chomp $name;
  $hostRoot=$Host;
  $hostRoot=~s/\d+$//;
  $name=~s/OST_$hostRoot\d+//;
  $name=~s/_UUID//;
  $name=~s/_//;
  $name=0    if $name eq '';

  return($name);
}

##################################################
#    These are MUCH faster than the linux commands
#    since we don't have to start a new process!
##################################################

sub cat
{
  my $file=shift;
  my $eof= shift;
  my $temp;

  if (!open CAT, "<$file")
  {
    logmsg("W", "Can't open '$file'");
    $temp='';
  }
  else
  {
    # if 'eof' set, return entire file, otherwise just 1st line.
    while (my $line=<CAT>)
    {
      $temp.=$line; 
      last    if !defined($eof);
    }
    close CAT;
  }
  return($temp);
}

sub ls
{
  my @dirs;
  opendir DIR, $_[0];
  while (my $line=readdir(DIR))
  {
    next    if $line=~/^\./;
    push @dirs, $line;
  }
  close DIR;
  return(@dirs);
}

1;
