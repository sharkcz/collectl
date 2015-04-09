# copyright, 2015 Hewlett-Packard Development Company, LP

# debug mask
#   1 - print interesting stuff
#   2 - include comments in stats data

# allow access to collectl variables, usually as readonly, but in this case we DO
# write to $verboseFlag
our ($intSecs, $hiResFlag, $SEP, $rate, $miniDateTime, $miniFiller);
our ($datetime, $showColFlag, $playback, $verboseFlag, $export);

# internal globals
my $version='1.0';
my ($debug, $options, $server, $stype, $ptype, $data);

my $logfile='/var/log/swift/swift-stats';
my $logfileOpen=0;

my %headers;
my %headlen;
$headers{'accaudt'}='Errs Pass Fail';
$headers{'accreap'}='Errs CFail CDel CRem CPoss OFail ODel ORem OPoss';
$headers{'accrepl'}='Diff DCap Nochg Hasm Rsync RMerg Atmpt Fail Remov Succ';
$headers{'accsrvr'}=' Put  Get Post Dele Head Repl Errs';
$headers{'conaudt'}='Errs Pass Fail';
$headers{'conrepl'}='Diff DCap Nochg Hasm Rsync RMerg Atmpt Fail Remov Succ';
$headers{'consrvr'}=' Put  Get Post Dele Head Repl Errs';
$headers{'consync'}='Skip Fail Sync Dele  Put';
$headers{'conupdt'}='Succ Fail NChg';
$headers{'objaudt'}='Quar Errs';
$headers{'objexpr'}=' Obj Errs';
$headers{'objrepl'}='PDel PUpd SHash SSync';
$headers{'objsrvr'}=' Put  Get Post Dele Head Repl Errs Quar Asyn PutTime';
$headers{'objupdt'}='Errs Quar Succ Fail ULink';
$headers{'prxyacc'}=' Put  Get Post Dele Head Copy Opts BadM Errs HCnt HACnt TOut DConn';
$headers{'prxycon'}=' Put  Get Post Dele Head Copy Opts BadM Errs HCnt HACnt TOut DConn';
$headers{'prxyobj'}=' Put  Get Post Dele Head Copy Opts BadM Errs HCnt HACnt TOut DConn';

my $valTypes={};
my $selTypes={};

my $returnFlag=0;
my $valid='aa ap ar as ca cr cs cy cu oa ox or os ou pa pc po';
foreach my $type (split(/ /, $valid))
{ $valTypes{$type}=''; }

sub statsdInit
{
  my $impOptsref=shift;
  my $impKeyref= shift;

  error("statsd must be called with --import NOT --export")     if $export=~/statsd/;

  $defServer='acop';
  $defStype='s';
  $defPtype='o';

  $data={};
  $debug=0;
  $versionFlag=0;
  $server=$stype=$ptype='';
  if (defined($$impOptsref))
  {
    foreach my $option (split(/,/,$$impOptsref))
    {
      my ($name, $value)=split(/=/, $option);
      if (length($name)==2)
      {
        $selTypes{$name}='';
	next;
      }
      error("invalid stats option: '$name'")    if $name !~/^[dfhprstv]$/;
      $debug=$value       if $name=~/d/ && defined($value);
      $logfile=$value     if $name=~/f/;
      $ptype=$value       if $name=~/p/;
      $returnFlag=1       if $name=~/r/;
      $server=$value      if $name=~/s/;
      $stype=$value       if $name=~/t/;
      $versionFlag=1      if $name=~/v/;
      statsdHelp()        if $name=~/h/;
    }
  }
  $server='acop'       if $server eq '*';
  $stype='ahlprsuxy'   if $stype eq '*';
  $ptype='aco'         if $ptype eq '*';

  error("server requires '=value'")         if !defined($server);
  error("service type requires '=value'")   if !defined($stype);
  error("proxy type requires '=value'")     if !defined($ptype);
  error("-s requires -t")                   if $server=~/[aco]/ && $stype eq '';
  error("-sp requires -p")                  if $server=~/p/ && $ptype eq '';

  # any switches force verbose mode
  $verboseFlag=1    if $server ne '' || $stype ne '' || $ptype ne '' || scalar(keys(%selTypes))!=0;

  # if nothing selected, use the defaults
  if ($server eq '' && $stype eq '' && $ptype eq '' && scalar(keys(%selTypes))==0)
  {
    $server=$defServer;
    $stype=$defStype;
    $ptype=$defPtype;
  }

  # if something selected it better be legal
  error('server must be a combination of a, c, o and p')       if $server ne '' && $server!~/^[acop]+$/g;
  error("service type must be a combination of 'ahlprsuxy'")   if $stype ne ''  && $stype!~/^[ahlprsuxy]+$/g;
  error("proxy type must be a combination of 'aco'")           if $ptype ne ''  && $ptype!~/^[aco]+$/g;

  # convert any of the -s/-t/-p values to valid selections possibly adding (or repeating)
  # any previous 2-char codes
  $selTypes{aa}=''    if $server=~/a/ && $stype=~/a/;
  $selTypes{ap}=''    if $server=~/a/ && $stype=~/p/;
  $selTypes{ar}=''    if $server=~/a/ && $stype=~/r/;
  $selTypes{as}=''    if $server=~/a/ && $stype=~/s/;
  $selTypes{ca}=''    if $server=~/c/ && $stype=~/a/;
  $selTypes{cr}=''    if $server=~/c/ && $stype=~/r/;
  $selTypes{cs}=''    if $server=~/c/ && $stype=~/s/;
  $selTypes{cy}=''    if $server=~/c/ && $stype=~/y/;
  $selTypes{cu}=''    if $server=~/c/ && $stype=~/u/;
  $selTypes{oa}=''    if $server=~/o/ && $stype=~/a/;
  $selTypes{ox}=''    if $server=~/o/ && $stype=~/x/;
  $selTypes{or}=''    if $server=~/o/ && $stype=~/r/;
  $selTypes{os}=''    if $server=~/o/ && $stype=~/s/;
  $selTypes{ou}=''    if $server=~/o/ && $stype=~/u/;
  $selTypes{pa}=''    if $server=~/p/ && $ptype=~/a/;
  $selTypes{pc}=''    if $server=~/p/ && $ptype=~/c/;
  $selTypes{po}=''    if $server=~/p/ && $ptype=~/o/;

  # both validate all the 2 char types AND make sure the server
  # types set in $server if not already so
  foreach my $type (keys %selTypes)
  {
    error("Invalid type: $type")    if !defined($valTypes{$type});
    my $svr=substr($type, 0, 1);
    $server.=$svr    if $server!~/$svr/;
  }
  #print "Server: $server  SType: $stype\n";

  if ($debug & 1)
  {
    print "Reading from: $logfile\n";
    foreach my $key (sort keys %selTypes)
    { print "$key "; }
    print "\n";
  }

  # the point of this is to initialize ALL data in case something is selected that
  # isn't part of the stats being reported.
  foreach my $type (keys %headers)
  {
    # remember \s+ needed because 'get/put' are space filled
    # and save number of headers in case needed later
    my $trimmed=$headers{$type};
    $trimmed=~s/^\s+//;
    $headnum{$type}=scalar(split(/\s+/, $trimmed));
    for (my $i=0; $i<split(/\s+/, $trimmed); $i++)
    { $data{$type}->{this}->[$i]=0; }
  }

  if ($versionFlag)
  {
    print "statsd V$version -s$server -t$stype -p$ptype\n";
    exit(0);
  }

  $$impOptsref='s';    # only summary data
  $$impKeyref='statsd';
  return(1);
}

# Anything you might want to add to collectl's header.  
sub statsdUpdateHeader
{
}

sub statsdGetData
{
  # rare that the log isn't aleady open other than duing initial passs,
  # perhaps at system startup
  if (!$logfileOpen)
  { $logfileOpen=1    if open LOG, "<$logfile"; }

  # but only if successfully opened
  if ($logfileOpen)
  {
    seek(LOG, 0, 0);
    while (my $line=<LOG>)
    {
      if (defined($line))
      {
        next    if $line=~/^#/;
	record(2, "statsd $line");
      }
    }
  }
}

sub statsdInitInterval
{
}

sub statsdAnalyze
{
  my $type=shift;    # not used
  my $dataref=shift;

  if ($$dataref!~/^#/ && $$dataref!~/V/)
  {
    my ($statsType, @fields)=split(/\s+/, $$dataref);

    return    if ($statsType=~/^a/ && $server!~/a/) ||
    	         ($statsType=~/^c/ && $server!~/c/) ||
    	         ($statsType=~/^o/ && $server!~/o/) ||
    	         ($statsType=~/^p/ && $server!~/p/);

    if (!defined($data{$statsType}->{last}))
    {
      for (my $i=0; $i<@fields; $i++)
      { $data{$statsType}->{last}->[$i]=0; }
    }

    for (my $i=0; $i<@fields; $i++)
    {
      # normally fields just contain raw counters, but in some cases they may contain a
      # return status code (such as with prxycon).  so let's be more general and when we
      # find a ':', treat the left-side as a subtype
      if ($fields[$i]!~/:/)
      {
        $data{$statsType}->{this}->[$i]=$fields[$i]-$data{$statsType}->{last}->[$i];
        $data{$statsType}->{last}->[$i]=$fields[$i];
      }
      else
      {
        # since subtypes are dynamic, we need to make sure if we're seeing for
	# the first time we properly initialize it.  Also note we want to use
	# a string for the subtype (to be more flexible) and so need a slightly
	# different structure since {last} and {this} point to arrays
        my ($subtype, $value)=split(/:/, $fields[$i]);
	$data{$statsType}->{sub}->{last}->{$subtype}=$value    if !defined($data{$statsType}->{sub}->{last}->{$subtype});
        $data{$statsType}->{sub}->{this}->{$subtype}=$value-$data{$statsType}->{sub}->{last}->{$subtype};
        $data{$statsType}->{sub}->{last}->{$subtype}=$value;
      }
    }
  }
}

sub statsdPrintBrief
{
  my $type=shift;
  my $lineref=shift;

  if ($type==1)       # header line 1
  {
    $$lineref.="<--------Ops--------|------Errors-------|-----Misc----->";
  }
  elsif ($type==2)    # header line 2
  {
    $$lineref.=" Acct Cont Objs Prxy Acct Cont Objs Prxy HOff Asyn Ulnk ";
  }
  elsif ($type==3)    # data
  {
    # first 5 ops ALWAYS put, get, post, delete and head
    my ($accOps, $conOps, $objOps, $prxOps)=(0,0,0,0);
    for (my $i=0; $i<6; $i++)
    {
      $accOps+=$data{accsrvr}->{this}->[$i]    if defined($data{accsrvr});
      $conOps+=$data{consrvr}->{this}->[$i]    if defined($data{consrvr});
      $objOps+=$data{objsrvr}->{this}->[$i]    if defined($data{objsrvr});

      # these are actually broken out by server type in the proxy
      $prxOps+=$data{prxyacc}->{this}->[$i]    if defined($data{prxyacc});
      $prxOps+=$data{prxycon}->{this}->[$i]    if defined($data{prxycon});
      $prxOps+=$data{prxyobj}->{this}->[$i]    if defined($data{prxyobj});
    }

    my ($accErrs, $conErrs, $objErrs, $prxErrs)=(0,0,0,0);
    $accErrs=$data{accsrvr}->{this}->[6]    if defined($data{accsrvr});
    $conErrs=$data{consrvr}->{this}->[6]    if defined($data{consrvr});
    $objErrs=$data{objsrvr}->{this}->[6]    if defined($data{objsrvr});

    # these are also by server type
    $prxErrs+=$data{prxyacc}->{this}->[8]    if defined($data{prxyacc});
    $prxErrs+=$data{prxycon}->{this}->[8]    if defined($data{prxycon});
    $prxErrs+=$data{prxyobj}->{this}->[8]    if defined($data{prxyobj});

    $handoff=(defined($data{prxsrvr})) ? $data{prxsrvr}->{this}->[9] : 0;
    $async=  (defined($data{objsrvr})) ? $data{objsrvr}->{this}->[8] : 0;
    $unlink= (defined($data{objupdt})) ? $data{objupdt}->{this}->[4] : 0;

    $$lineref.=sprintf(" %4d %4d %4d %4d %4d %4d %4d %4d %4d %4d %4d",
    			 $accOps/$intSecs, $conOps/$intSecs,
			 $objOps/$intSecs, $prxOps/$intSecs,
    			 $accErrs/$intSecs, $conErrs/$intSecs,
			 $objErrs/$intSecs, $prxErrs/$intSecs,
			 $handoff/$intSecs, $async/$intSecs,
			 $unlink/$intSecs);
  }
  elsif ($type==4)    # reset 'total' counters
  {
  }
  elsif ($type==5)    # increment 'total' counters
  {
  }
  elsif ($type==6)    # print 'total' counters
  {
  }
}

sub statsdPrintVerbose
{
  my $printHeader=shift;
  my $homeFlag=   shift;
  my $lineref=    shift;

  # when mixing multiple server types the column spacing can get messed up
  my $has_acc=($server=~/a/ && $stype=~/[arls]/) ? 1 : 0;
  my $has_con=($server=~/c/ && $stype=~/[arsyu]/) ? 1 : 0;
  my $has_obj=($server=~/c/ && $stype=~/[axlsu]/) ? 1 : 0;

  #    P r i n t    1 s t    H e a d e r    L i n e

  # Note that last line of verbose data (if any) still sitting in $$lineref
  my $line=$temp='';
  if ($printHeader)
  {
    $line.="#$miniFiller";

    my ($acc_width, $con_width, $obj_width)=(0,0,0);
    if ($server=~/a/)
    {
      $temp='';
      $temp.="---Auditor----|"                                            if defined($selTypes{aa});
      $temp.="---------------------Reaper---------------------|"          if defined($selTypes{ap});
      $temp.="----------------------Replicator----------------------|"    if defined($selTypes{ar});
      $temp.="--------------Server--------------|"                        if defined($selTypes{as});
      $temp=~s/\|$/>/;
      $line.="<$temp"    if $temp ne '';
      $acc_width=length($temp);
    }

    if ($server=~/c/)
    {
      $temp='';
      $temp.="---Auditor----|"                                            if defined($selTypes{ca});
      $temp.="----------------------Replicator----------------------|"    if defined($selTypes{cr});
      $temp.="--------------Server--------------|"                        if defined($selTypes{cs});
      $temp.="----------Sync----------|"                                  if defined($selTypes{cy});
      $temp.="---Updater----|"                                            if defined($selTypes{cu});
      $temp=~s/\|$/>/;
      $line.="<$temp"    if $temp ne '';
      $con_width=length($temp);
    }

    if ($server=~/o/)
    {
      $temp='';
      $temp.="-Auditor-|"                                                 if defined($selTypes{oa});
      $temp.="-Expirer-|"                                                 if defined($selTypes{ox});
      $temp.="-----Replicator------|"                                     if defined($selTypes{or});
      $temp.="-----------------------Server-----------------------|"      if defined($selTypes{os});
      $temp.="---------Updater---------|"                                 if defined($selTypes{ou});
      $temp=~s/\|$/>/;
      $line.="<$temp"    if $temp ne '';
      $obj_width=length($temp);
    }

    # if including html status codes we need to calculate extra padding
    # which though a pain in the butt is worth it
    my ($pre, $post)=('','');
    if (defined($selTypes{pa}))
    {
      if ($returnFlag)
      {
        my $pad=0;
        foreach my $key (sort keys %{$data{prxyacc}->{sub}->{this}})
        { $pad+=5; }
        $pre=$post='-' x int($pad/2);
        $post.='-'    if $pad % 2 != 0;    # if odd...
      }
      $line.="<$pre-------------------------Proxy Acc Server$post------------------------->";
    }

    if (defined($selTypes{pc}))
    {
      if ($returnFlag)
      {
        my $pad=0;
        foreach my $key (sort keys %{$data{prxycon}->{sub}->{this}})
        { $pad+=5; }
        $pre=$post='-' x int($pad/2);
        $post.='-'    if $pad % 2 != 0;    # if odd...
      }
      $line.="<$pre-------------------------Proxy Con Server$post------------------------->";
    }

    if (defined($selTypes{po}))
    { 
      if ($returnFlag)
      {
        my $pad=0;
        foreach my $key (sort keys %{$data{prxyobj}->{sub}->{this}})
        { $pad+=5; }
        $pre=$post='-' x int($pad/2);
        $post.='-'    if $pad % 2 != 0;    # if odd...
      }
      $line.="<$pre-------------------------Proxy Obj Server$post------------------------->";
    }
    $line.="\n";

    # real ugly, but once we know the lenghts of each section, we can
    # preface the headers with the section names.  it's still not
    # perfect in all cases but it's close enough!
    my $pre_header='';
    if ($acc_width)
    {
      my ($pre, $post)=getpad($acc_width, 'Account');
      $temp="${pre}Account$post";
      $pre_header.=" $temp";
    }
    if ($con_width)
    {
      my ($pre, $post)=getpad($con_width, 'Container');
      $temp="${pre}Container$post";
      $pre_header.=" $temp";
    }
    if ($obj_width)
    {
      my ($pre, $post)=getpad($obj_width, 'Object');
      $temp="${pre}Object$post";
      $pre_header.=" $temp";
    }
    $line="#$miniFiller$pre_header\n$line";

    #    P r i n t    2 n d    H e a d e r    L i n e

    $line.="#$miniDateTime";
    if ($server=~/a/)
    {
      $temp='';
      $temp.="$headers{'accaudt'} "    if defined($selTypes{aa});
      $temp.="$headers{'accreap'} "    if defined($selTypes{ap});
      $temp.="$headers{'accrepl'} "    if defined($selTypes{ar});
      $temp.="$headers{'accsrvr'} "    if defined($selTypes{as});
      $temp=~s/\|$/ /;
      $line.=" $temp"    if $temp ne '';
    }

    if ($server=~/c/)
    {
      $temp='';
      $temp.="$headers{'conaudt'} "    if defined($selTypes{ca});
      $temp.="$headers{'conrepl'} "    if defined($selTypes{cr});
      $temp.="$headers{'consrvr'} "    if defined($selTypes{cs});
      $temp.="$headers{'consync'} "    if defined($selTypes{cy});
      $temp.="$headers{'conupdt'} "    if defined($selTypes{cu});
      $temp=~s/\|$/ /;
      $line.=" $temp"    if $temp ne '';
    }

    if ($server=~/o/)
    {
      $temp='';
      $temp.="$headers{'objaudt'} "    if defined($selTypes{oa});
      $temp.="$headers{'objexpr'} "    if defined($selTypes{ox});
      $temp.="$headers{'objrepl'} "    if defined($selTypes{or});
      $temp.="$headers{'objsrvr'} "    if defined($selTypes{os});
      $temp.="$headers{'objupdt'} "    if defined($selTypes{ou});
      $line.=" $temp"    if $temp ne '';
    }

    # when ONLY reporting on proxies we need an extra space to start thing out right
    $line.=' '    if $server eq 'p';
    if (defined($selTypes{pa}))
    {
      $line.="$headers{'prxyacc'} ";
      if ($returnFlag)
      {
        foreach my $key (sort keys %{$data{prxyacc}->{sub}->{this}})
        { $line.=sprintf("%4s ", $key); }
      }
    }

    if (defined($selTypes{pc}))
    {
      $line.="$headers{'prxycon'} ";
      if ($returnFlag)
      {
        foreach my $key (sort keys %{$data{prxycon}->{sub}->{this}})
        { $line.=sprintf("%4s ", $key); }
      }
    }

    if (defined($selTypes{po}))
    {
      $line.="$headers{'prxyobj'} ";
      if ($returnFlag)
      {
        foreach my $key (sort keys %{$data{prxyobj}->{sub}->{this}})
        { $line.=sprintf("%4s ", $key); }
      }
    }
    $line.="\n";
  }
  $$lineref=$line;
  return    if $showColFlag;

  #    P r i n t    D a t a

  $line='';
  foreach my $serverType ('acc', 'con', 'obj', 'prxy')
  {
    my $serverShort=substr($serverType, 0, 1);
    next    if $server!~/$serverShort/;

    # if we printed any data for acc/con, we may need to shift over a space
    $line.=' '    if $serverType eq 'con' && $has_acc;
    $line.=' '    if $serverType eq 'obj' && ($has_acc || $has_con);

    for my $dataType (sort keys %headers)
    {
      next    if $dataType!~/^$serverType/;
      my $subType=($serverShort ne 'p') ? substr($dataType, 3, 1) : substr($dataType, 4, 1);
      $subType='p'    if $dataType=~/reap$/;
      $subType='x'    if $dataType=~/expr$/;
      $subType='y'    if $dataType=~/sync$/;
      next    if !defined($selTypes{"$serverShort$subType"});

      # we need to trim leading whitespace or first field will be empty
      my $trimmed=$headers{$dataType};
      $trimmed=~s/^\s+//;
      @fields=split(/\s+/, $trimmed);
      #printf "DType: $dataType  Trimmed: $trimmed  NUM: %d\n", scalar(@fields);


      # last field for objsrvr is special because it's a composite of 9 and 10
      my $type="$serverType$subType";
      for (my $i=0; $i<@{$data{$dataType}->{this}}; $i++)
      {
         if ($type ne 'objs' || $i<9)
	 {
	   $width=length($fields[$i]);
	   $width=4    if $width==3;
	   $line.=sprintf(" %${width}d", $data{$dataType}->{this}->[$i]/$intSecs);
	 }
	 elsif ($type eq 'objs' && $i==10)
	 {
	   # make sure there's a non-zero value to compute
	   $secs=($data{$dataType}->{this}->[9]) ?
	       $data{$dataType}->{this}->[10]/$data{$dataType}->{this}->[9] : 0;
           $line.=sprintf(" %7.3f", $secs);
	 }
      }

      # only proxy data has return codes
      if ($serverShort eq 'p' && $returnFlag)
      {
        foreach my $key (sort keys %{$data{$dataType}->{sub}->{this}})
        { $line.=sprintf(" %4d", $data{$dataType}->{sub}->{this}->{$key}/$intSecs); }
      }
    }
  }
  $$lineref.="$datetime $line\n";
}

# NOTE - only summary data collected
sub statsdPrintPlot 
{
  my $type=   shift;
  my $ref1=   shift;

  foreach my $serverType ('acc', 'con', 'obj', 'prxy')
  {
    my $serverShort=substr($serverType, 0, 1);
    next    if $server!~/$serverShort/;

    for my $dataType (sort keys %headers)
    {
      next    if $dataType!~/^$serverType/;
      {
        # the single char subtype is the 4th char in the datatype
	# except for proxy servers in which case it's the 5th.
	# Also for 'reap', 'expr' and 'sync' we need to reset the subtype
        my $subType=($serverShort ne 'p') ? substr($dataType, 3, 1) : substr($dataType, 4, 1);
        $subType='p'    if $dataType=~/reap$/;
        $subType='x'    if $dataType=~/expr$/;
        $subType='y'    if $dataType=~/sync$/;
        next    if !defined($selTypes{"$serverShort$subType"});
        #print "DataType: $dataType Short: $serverShort  SvcType: $stype  SubType: $subType\n";

        if ($type==1)
        {
	  # need to get rid of leading whitespace before split
	  my $trimmed=$headers{$dataType};
	  $trimmed=~s/^\s+//;
  	  for my $header (split(/\s+/, $trimmed))
	  { $$ref1.=sprintf("[SW-%s]$header${SEP}", uc($dataType)); }
        }
        else
        {
          my $type="$serverType$subType";
	  for (my $i=0; $i<@{$data{$dataType}->{this}}; $i++)
	  {
            if ($type ne 'objs' || $i<9)
	    { $$ref1.=sprintf("$SEP%d", $data{$dataType}->{this}->[$i]/$intSecs); }
	    elsif ($type eq 'objs' && $i==10)
	    {
               # make sure there's a non-zero value to compute
               $secs=($data{$dataType}->{this}->[9]) ?
                   $data{$dataType}->{this}->[10]/$data{$dataType}->{this}->[9] : 0;
	      $$ref1.=sprintf("$SEP%.3f", $secs);
	    }
	  }
	}
      }
    }
  }
}

# REMEMBER - only summary data collected
sub statsdPrintExport
{
  my $type=shift;
  my $ref1=shift;
  my $ref2=shift;
  my $ref3=shift;
  my $ref4=shift;
  my $ref5=shift;
  my $ref6=shift;

  if ($type eq 'l')
  {
  }
  elsif ($type eq 'g')
  {
  }
}

sub getpad
{
  my $width=shift;
  my $title=shift;

  # here's the problem, with width we're being passed include the terminatin '>'
  # in the header but we want to centers over the ----s.  So, if the pad is an
  # even number we want to shift one to the left.  But if odd, we come up sort
  # in our pad chars so add one more to the right because that's how the uneven
  # headers centering is done.
  my $totpad=$width-length($title);
  my $pad=int($totpad/2);
  my $pre=$post=' ' x $pad;
  if ($totpad % 2 == 0)
  {
    $pre=' ' x ($pad-1);
    $post=' ' x ($pad+1);
  }
  else
  {
    $pre=' ' x $pad;
    $post=' ' x ($pad+1);
  }
  return($pre, $post);
}

sub statsdHelp
{
  my $help=<<STATSDEOF;

usage: statsd, switches...
  d=mask  debug mask, see header for details
  h       print this help test
  f file  reads stats from specified file
  r       include return codes with proxy stats
  s       server: a, c, o and/or p
  t       data type to report, noting from the following
          that not all servers report all types

           t  name             servers
           a  auditor       acc  con  obj
           x  expirer                 obj
           p  reaper        acc   
           r  replicator    acc  con  obj
           s  server        acc  con  obj
           y  sync               con
           u  updater            con  obj

  p	   proxies require their own service type
	   a  account service
           c  container service
           o  object service

  v        show version and default settings
  xx       2 char specific types built from -s, -t and -p

  NOTE = setting s, t or p to * selects everything

STATSDEOF

  print $help;
  exit(0);
}

1;
