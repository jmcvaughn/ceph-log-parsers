#!/usr/bin/env awk -f

#######################################################
#######################################################
##
## Run with ceph.log and redirect output to a CSV
## 
## ./ceph_log_parser.awk ceph.log > ceph-log-parsed.csv
## ./ceph_log_parser.awk -v osdtree=ceph_osd_tree.txt -v timeinterval=60 -v bucketsummary=1 ceph.log > ceph-log-parsed.csv
##
##
## Available options:
##      -v osdtree=ceph_osd_tree.txt
##          If provided, the osd output portion will be output with its branch path in the crushmap
##
##      -v timeinterval=(1|10|60|day)
##          If provided, adjusts the time alignment for the histogram output.  Default is 10 (minutes)
##
##      -v bucketsummary=1
##          If provided, provides an output below the OSD data summarizing the OSD counts for each 
##          successive bucket branch above the OSD ( example: host, rack, row, root )
##          Default is 1 if 'osdtree' is defined.
##
##      -v osdhisto=1
##          Provides a column per OSD in the time histogram showing initial 'slow request' entries 
##          incurred by that OSD during the time interval.
##          Default is disabled because this can make VERY wide spreadsheets
##
##      NOTE: These options MUST be specified **BEFORE** the ceph.log file, otherwise they will be
##            ignored
##
## * For items which are average, these are summed and averaged over the measurement interval
##   The measurement is reported at the beginning of the interval measurement period
##   e.g IO: Client Read MB/s for 03:30 to 03:40 is averaged, then reported on the 03:30 line
##
## * For items which are a static snapshot, these are reported based on the last line containing those
##   details in the log before the end of the measurement interval
##   e.g. PG: active for 03:30 to 03:40 - If a pgmap is found at 03:39:59, that will be the one reported for
##        the 03:30 line
##
## * For items like the Slow requests, the count of those entries is summed during the 10 minute period and reported
##   e.g. If there are 50 'slow request ' logs in the 10 minute interval which are for a primary OSD, then 50 is reported
##        If there are 50 'slow request ' logs 'waiting for subop', then the OSDs called out by the subop (comma
##        separated numbers), are all counted in the 'Slow SubOp' line.  For 3x replication, and 50 lines, the reported 
##        number would be 100 (due to 2x non-primary copies * 50 lines)
##
##
#######################################################
#######################################################



function toMB(mynum,myunit) {
  myunit=tolower(myunit)
  if (myunit ~  /^b/) { mynum/=(1024*1024); }
  else if (myunit ~ /^kb/) { mynum/=1024; }
  else if (myunit ~ /^gb/) { mynum*=1024; }
  else if (myunit ~ /^tb/) { mynum*=1024*1024; }
  return sprintf("%0.2f",mynum)
}

function toTB(mynum,myunit) {
  myunit=tolower(myunit)
  if (myunit ~  /^b/) { mynum/=(1024*1024*1024*1024) }
  else if (myunit ~ /^kb/) { mynum/=(1024*1024*1024) }
  else if (myunit ~ /^mb/) { mynum/=(1024*1024) }
  else if (myunit ~ /^gb/) { mynum/=1024 }
  else if (myunit ~ /^pb/) { mynum*=1024 }
  else if (myunit ~ /^eb/) { mynum*=1024*1024 }
  return sprintf("%0.2f",mynum)
}

function join(array,sep) {
  if(1 in array) {
    result=array[1]
    arraylen=length(array)
    if(arraylen>1) {
      for(z=2;z<=arraylen;z++)
        result = result sep array[z]
    }
  }
  return result
}

function procbranch(myline) {
  split(myline,lineparts," ")
  if(lineparts[3] in branchtype) {
    if(currentdepth>branchtype[lineparts[3]]) {
      for(i=currentdepth;i>branchtype[lineparts[3]];i--) {
        delete prefix[i]
        delete branchtype[i]
      }
      delete prefix[branchtype[lineparts[3]]]
    }
  } else {
    currentdepth++
    branchtype[lineparts[3]]=currentdepth
  }
  prefix[branchtype[lineparts[3]]]=lineparts[4]
  wasinhost=0
}

function procosd(myline) {
  split(myline,lineparts," ")
  outline=join(prefix,",")
  if(classenable==1)
    outline=outline","lineparts[2]
  osdpaths[lineparts[osdoffset]]=outline
  outline=outline","lineparts[osdoffset]
  osdpathsbypath[outline]=lineparts[osdoffset]
  if(currentdepth>maxpathdepth)
    maxpathdepth=currentdepth
}

function histoevent(mykey,myevent,myfunc,myvalue) {
  EVENTHEADERS[myevent]=1
  if(myfunc=="sum")
    EVENTCOUNT[mykey][myevent]+=myvalue
  else if(myfunc=="set")
    EVENTCOUNT[mykey][myevent]=myvalue
  else if(myfunc=="inc")
    EVENTCOUNT[mykey][myevent]++
}

function histototal(myevent,myvalue) {
  EVENTTOTAL[myevent]+=myvalue
}

function osdhistoevent(mykey,myevent,myfunc,myvalue) {
  if(osdhisto!="") {
    OSDEVENTHEADERS[myevent]=1
    if(myfunc=="sum")
      OSDEVENTCOUNT[mykey][myevent]+=myvalue
    else if(myfunc=="set")
      OSDEVENTCOUNT[mykey][myevent]=myvalue
    else if(myfunc=="inc")
      OSDEVENTCOUNT[mykey][myevent]++
  }
}

function osdhistototal(myevent,myvalue) {
  if(osdhisto!="")
    OSDEVENTTOTAL[myevent]+=myvalue
}

function osdevent(mykey,myevent,myfunc,myvalue) {
  OSDHEADERS[myevent]=1
  if(myfunc=="sum")
    OSDEVENT[mykey][myevent]+=myvalue
  else if(myfunc=="set")
    OSDEVENT[mykey][myevent]=myvalue
  else if(myfunc=="inc")
    OSDEVENT[mykey][myevent]++
}

function osdtotal(myevent,myvalue) {
  OSDTOTAL[myevent]+=myvalue
}

function poolevent(mykey,myevent,myfunc,myvalue) {
  POOLHEADERS[myevent]=1
  if(myfunc=="sum")
    POOLEVENT[mykey][myevent]+=myvalue
  else if(myfunc=="set")
    POOLEVENT[mykey][myevent]=myvalue
  else if(myfunc=="inc")
    POOLEVENT[mykey][myevent]++
  else if(myfunc=="max") {
    if(myvalue>POOLEVENT[pgparts[1]][myevent] || POOLEVENT[pgparts[1]][myevent] == "")
      POOLEVENT[pgparts[1]][myevent]=myvalue
  } else if(myfunc=="min") {
    if(myvalue<POOLEVENT[pgparts[1]][myevent] || POOLEVENT[pgparts[1]][myevent] == "")
      POOLEVENT[pgparts[1]][myevent]=myvalue
  }
}

function mydtstamp(mydt) {
  if ( timeinterval==10 )
    return sprintf("%s0",substr(mydt,1,15))
  else if (timeinterval==1)
    return sprintf("%s",substr(mydt,1,16))
  else if (timeinterval==60)
    return sprintf("%s:00",substr(mydt,1,13))
  else if (timeinterval=="day")
    return sprintf("%s 00:00",substr(mydt,1,10))
}

BEGIN {
  if(timeinterval=="")
    timeinterval=10

  if(osdtree != "") {
    if(bucketsummary=="")
      bucketsummary==1
    maxpathdepth=0
    currentdepth=0
    wasinhost=0
    while(( getline line<osdtree ) > 0 ) {
      split(line,osdtreeparts," ")
      switch (osdtreeparts[1]) {
        case "ID":
          classenable=0
          osdoffset=3
          if(osdtreeparts[2]=="CLASS") {
            classenable=1
            osdoffset=4
          }
          break
        case /^ *-/:
          procbranch(line)
          break
        case /^ *[0-9]/:
          wasinhost=1
          procosd(line)
          break
      }
    }
  }
}

/ overall HEALTH/ {
  if($NF == "HEALTH_OK")
    next
  MYDTSTAMP=mydtstamp($1" "$2)
  myline=$0
  myeventadd=0
  split(myline,mlpa," : ")
  split(mlpa[2],mylineparts,";")

  for(linepartindex in mylineparts) {
    switch (mylineparts[linepartindex]) {
      case / osds down$/:
        split(mylineparts[linepartindex],osdparts," ")
        histoevent(MYDTSTAMP,"OSDs down","set",osdparts[5])
        break
      case / host.*down$/:
        split(mylineparts[linepartindex],hostparts," ")
        histoevent(MYDTSTAMP,"HOSTs down","set",hostparts[1])
        break
      case /Reduced data availability: /:
      case /Possible data damage: /:
        split(mylineparts[linepartindex],linepartA,":")
        split(linepartA[2],linepartB,",")
        for(field in linepartB) {
          split(linepartB[field],fparts," ")
          myevent="PG: "fparts[3]
          histoevent(MYDTSTAMP,myevent,"set",fparts[1])
        }
        break
      case /Degraded data redundancy: /:
        split(mylineparts[linepartindex],linepartA,":")
        split(linepartA[2],linepartB,",")
        for(field in linepartB) {
          if(linepartB[field] ~ /objects degraded/) {
            split(linepartB[field],linepartC," ")
            gsub(/[^0-9\.]/,"",linepartC[4])
            histoevent(MYDTSTAMP,"Objects: Degraded Percent","set",linepartC[4])
          } else {
            split(linepartB[field],fparts," ")
            myevent="PG: "fparts[3]
            histoevent(MYDTSTAMP,myevent,"set",fparts[1])
          }
        }
        break
      case / objects misplaced /:
        split(mylineparts[linepartindex],degradeobj," ")
        gsub(/[^0-9\.]/,"",degradeobj[4])
        histoevent(MYDTSTAMP,"Objects: Misplaced Percent","set",degradeobj[4])
        break
    }
  }
}

/ deep-scrub / {
  MYDTSTAMP=mydtstamp($1" "$2)
  MYPG=$9
  MYDATE=$1
  MYTIME=$2
  gsub(/[-:]/," ",MYDATE)
  gsub(/[-:]/," ",MYTIME)
  MYTIME=mktime(MYDATE" "MYTIME)
  split($2,secs,".")
  millisecs=sprintf("0.%s",secs[2])
  MYTIME+=millisecs

  if($NF == "starts") {
    MYEVENT="Deep-Scrub: Starts"
    histoevent(MYDTSTAMP,MYEVENT,"inc")
    osdevent($3,MYEVENT,"inc")
    osdtotal(MYEVENT,1)
    histototal(MYEVENT,1)
    MYSTART[MYPG]=MYTIME
  }
  else {
    if(MYSTART[MYPG]!="") {
      mydiff=MYTIME-MYSTART[MYPG]
      split(MYPG,pgparts,".")
      poolevent(pgparts[1],"Deep-Scrub: Count","inc")
      poolevent(pgparts[1],"Deep-Scrub: Total","sum",mydiff)
      poolevent(pgparts[1],"Deep-Scrub: Min","min",mydiff)
      poolevent(pgparts[1],"Deep-Scrub: Max","max",mydiff)
    }
    if($NF == "ok") {
      MYEVENT="Deep-Scrub: OK"
      histoevent(MYDTSTAMP,MYEVENT,"inc")
      histototal(MYEVENT,1)
      osdevent($3,MYEVENT,"inc")
      osdtotal(MYEVENT,1)
    } else {
      MYEVENT="Deep-Scrub: Not OK"
      histoevent(MYDTSTAMP,MYEVENT,"inc")
      histototal(MYEVENT,1)
      osdevent($3,MYEVENT,"inc")
      osdtotal(MYEVENT,1)
    }
  }
}

/slow request / {
  MYDTSTAMP=mydtstamp($1" "$2)
  MYLINE=$0
  split(MYLINE,myparts,":")
  split(myparts[9],opparts," ")
  if (opparts[2] ~ /^[0-9]*\.[0-9a-f]*$/)
    split(opparts[2],pgid,".")
  else if (opparts[9] ~ /^[0-9]*\.[0-9a-f]*/)
    split(opparts[9],pgid,".")
  else if (myparts[8] ~ /pg_update_log_missing/) {
    split(myparts[8],temppgid," ")
    gsub(/^.*\(/,"",temppgid[1])
    split(temppgid[1],pgid,".")
  }
 
  if ($0 ~ / subops /) {
    split($0,junk," currently ")
    MYTYPE="Slow SubOp: "junk[2]
    gsub(/ [0-9,]*$/,"",MYTYPE)
    split($NF,subosds,",")
    for (subosd in subosds) {
      subosd="osd."subosds[subosd]
      if($12 < 60) {
        myeventstring="Slow SubOp,Slow Total,"MYTYPE
        osdhistoevent(MYDTSTAMP,subosd,"inc")
        osdhistototal(subosd,"inc")
      } else {
        myeventstring="Slow Relog SubOp,Slow Relog Total"
      }
      split(myeventstring,myevents,",")
      for(myevent in myevents) {
        histototal(myevents[myevent],1)
        histoevent(MYDTSTAMP,myevents[myevent],"inc")
        osdevent(subosd,myevents[myevent],"inc")
        osdtotal(myevents[myevent],1)
        poolevent(pgid[1],myevents[myevent],"inc")
      }
    }
  } else {
    split($0,junk," currently ")
    MYTYPE="Slow Primary: "junk[2]
    gsub(/ from [0-9]*/,"",MYTYPE)
    if($12 < 60) {
      myeventstring="Slow Primary,Slow Total,"MYTYPE
      osdhistoevent(MYDTSTAMP,$3,"inc")
      osdhistototal($3,"inc")
    } else {
      myeventstring="Slow Relog Primary,Slow Relog Total"
    }
    split(myeventstring,myevents,",")
    for(myevent in myevents) {
      histoevent(MYDTSTAMP,myevents[myevent],"inc")
      histototal(myevents[myevent],1)
      osdevent($3,myevents[myevent],"inc")
      osdtotal(myevents[myevent],1)
      poolevent(pgid[1],myevents[myevent],"inc")
    }
  }
}

/ osdmap / {
  MYDTSTAMP=mydtstamp($1" "$2)
  histoevent(MYDTSTAMP,"OSDs","set",$11)
  histoevent(MYDTSTAMP,"OSDs UP","set",$13)
  histoevent(MYDTSTAMP,"OSDs IN","set",$15)
}

/ osd\.[0-9]* out / {
  MYDTSTAMP=mydtstamp($1" "$2)
  MYEVENT="OSD Out"
  histoevent(MYDTSTAMP,MYEVENT,"inc")
  histototal(MYEVENT,1)
  if($9 ~ /^osd\./)
    osdpos=9
  if($11 ~ /^osd\./)
    osdpos=11
  osdevent($osdpos,MYEVENT,"inc")
  osdtotal(MYEVENT,1)
}

/ but it is still running$/ {
  MYDTSTAMP=mydtstamp($1" "$2)
  MYEVENT="OSD Wrongly"
  histoevent(MYDTSTAMP,MYEVENT,"inc")
  histototal(MYEVENT,1)
  osdevent($3,MYEVENT,"inc")
  osdtotal(MYEVENT,1)
}

/ wrongly marked me down$/ {
  MYDTSTAMP=mydtstamp($1" "$2)
  MYEVENT="OSD Wrongly"
  histoevent(MYDTSTAMP,MYEVENT,"inc")
  histototal(MYEVENT,1)
  osdevent($3,MYEVENT,"inc")
  osdtotal(MYEVENT,1)
}

/ marked itself down / {
  MYDTSTAMP=mydtstamp($1" "$2)
  MYEVENT="OSD Down: Self"
  histoevent(MYDTSTAMP,MYEVENT,"inc")
  histototal(MYEVENT,1)
  osdevent($9,MYEVENT,"inc")
  osdtotal(MYEVENT,1)
}

/no active mgr/ {
  MYDTSTAMP=mydtstamp($1" "$2)
  MYEVENT="MGR: None Active"
  histoevent(MYDTSTAMP,MYEVENT,"inc")
  histototal(MYEVENT,1)
}

/ calling new monitor election$/ {
  MYDTSTAMP=mydtstamp($1" "$2)
  MYEVENT="MON: Calling Election"
  histoevent(MYDTSTAMP,MYEVENT,"inc")
  histototal(MYEVENT,1)
}

/ failed .*report.*from / {
  MYDTSTAMP=mydtstamp($1" "$2)
  MYEVENT="OSD Down: Reported Failed"
  histoevent(MYDTSTAMP,MYEVENT,"inc")
  histototal(MYEVENT,1)
  if($9 ~ /^osd\./)
    osdpos=9
  if($10 ~ /^osd\./)
    osdpos=10
  osdevent($osdpos,MYEVENT,"inc")
  osdtotal(MYEVENT,1)
}

/ marked down after no pg stats for / {
  MYDTSTAMP=mydtstamp($1" "$2)
  MYEVENT="OSD Down: No PG stats"
  histoevent(MYDTSTAMP,MYEVENT,"inc")
  histototal(MYEVENT,1)
  osdevent($9,MYEVENT,"inc")
  osdtotal(MYEVENT,1)
}

/ boot$/ {
  MYDTSTAMP=mydtstamp($1" "$2)
  MYEVENT="OSD Boot"
  histoevent(MYDTSTAMP,MYEVENT,"inc")
  histototal(MYEVENT,1)
  osdevent($10,MYEVENT,"inc")
  osdtotal(MYEVENT,1)
}

END {

  ## Begin outputting the histogram chart
  printf("DateTime")
  n=asorti(EVENTHEADERS)
  if(osdhisto!="")
    osdn=asorti(OSDEVENTHEADERS)
  for (i = 1; i<= n; i++ )
    printf(",%s",EVENTHEADERS[i])
  if(osdhisto!="") {
    for (i = 1; i<= osdn; i++)
      printf(",%s",OSDEVENTHEADERS[i])
  }

  printf("\n")

  dtcount=asorti(EVENTCOUNT,DTS)

  for (dtindex =1; dtindex <= dtcount; dtindex++) {
    DT=DTS[dtindex]
    printf("%s:00", DT)
    for (i = 1; i<= n; i++ )
      printf(",%s",EVENTCOUNT[DT][EVENTHEADERS[i]])
    if(osdhisto!="") {
      # add-on the per OSD histo columns
      for (i = 1; i<= osdn; i++ )
        printf(",%s",OSDEVENTCOUNT[DT][OSDEVENTHEADERS[i]])
    }
    printf("\n")
  }

  ## Begin outputting the column totals line
  printf("Totals")
  for (i = 1; i<= n; i++ )
    printf(",%s",EVENTTOTAL[EVENTHEADERS[i]])
  if(osdhisto!="") {
    for (i = 1; i<= osdn; i++ )
      printf(",%s",OSDEVENTTOTAL[OSDEVENTHEADERS[i]])
  }

  printf("\n")
  printf("\n")

  ## Begin outputting the OSD chart
  o=asorti(OSDHEADERS,OHDR)

  if(osdtree != "") {
    printf("OSD Tree Path,")
    for(pathindex=2;pathindex<=maxpathdepth;pathindex++)
      printf(",")
  }

  printf("osd.id")
  for (i = 1; i<= o; i++ ) {
    printf(",%s",OHDR[i])
  }
  printf("\n")
  
  if(osdtree=="") {
    for (OSD in OSDEVENT) {
      gsub(/^osd\./,"",OSD)
      OSDS[OSD]=OSD
    }
    osdcount=asort(OSDS)
  } else {
    osdcount=asorti(osdpathsbypath,OSDS)
  }
  for (osdindex=1; osdindex<=osdcount; osdindex++) {
    if(osdtree=="")
      osd="osd."OSDS[osdindex]
    else {
      osd=OSDS[osdindex]
      split(OSDS[osdindex],osdparts,",")
      osd=osdparts[length(osdparts)]

      printf("%s,",osdpaths[osd])
      split(osdpaths[osd],pathjunk,",")
      pathdepth=length(pathjunk)
      if(pathdepth<maxpathdepth) {
        for(pathindex=(pathdepth+1);pathindex<maxpathdepth;pathindex++)
          printf(",")
      }
    }
    printf("%s",osd)
    for (i = 1; i<= o; i++ ) {
      printf(",%s",OSDEVENT[osd][OHDR[i]])
      if(bucketsummary != "" && osdtree != "") {
        mypath=osdpaths[osd]
        do {
          lastmypath=mypath
          BUCKETSUMMARY[mypath][OHDR[i]]+=OSDEVENT[osd][OHDR[i]]
          gsub(/,[^,]*$/,"",mypath)
        } while (lastmypath!=mypath)
      }
    }
    printf("\n")
  }
  ## Begin outputting OSDs which were not in the OSD tree
  if(osdtree != "") {
    delete OSDS
    for (OSD in OSDEVENT) {
      gsub(/^osd\./,"",OSD)
      OSDS[OSD]=OSD
    }
    osdcount=asort(OSDS)
    for (osdindex=1; osdindex<=osdcount; osdindex++) {
      osd="osd."OSDS[osdindex]
      if(osdpaths[osd] == "") {
        for(pathindex=1;pathindex<maxpathdepth;pathindex++)
          printf(",")
        printf("%s",osd)
        for (i = 1; i<= o; i++ )
          printf(",%s",OSDEVENT[osd][OHDR[i]])
        printf("\n")
      }
    }
  }
  ## Begin outputting the OSD Bucket summary chart
  if(bucketsummary != "" && osdtree != "") {
    buckets=asorti(BUCKETSUMMARY,BKS)
    for(bindex=buckets;bindex>=1;bindex--) {
      printf("%s,",BKS[bindex])
      split(BKS[bindex],bucketjunk,",")
      junklen=length(bucketjunk)
      for(i=junklen; i< maxpathdepth; i++)
        printf(",")
      for (i = 1; i<= o; i++ ) {
        if(BUCKETSUMMARY[BKS[bindex]][OHDR[i]]>0)
          printf(",%s",BUCKETSUMMARY[BKS[bindex]][OHDR[i]])
        else
          printf(",")
      }
      printf("\n")
    }
  } else {
    ## Or print column totals if Bucket Summary is not selected
    printf("Totals")
    if(osdtree != "") {
      for(pathindex=2;pathindex<=maxpathdepth;pathindex++)
        printf(",")
    }
    for (i = 1; i<= o; i++ ) {
      printf(",%s",OSDTOTAL[OHDR[i]])
    }
  }

  printf("\n\n")

  ## Begin outputting the Pool summary chart
  if ("Deep-Scrub: Count" in POOLHEADERS) {
    POOLHEADERS["Deep-Scrub: Average"]=1
  }
  poolcount=asorti(POOLEVENT,poolids)
  phdrcount=asorti(POOLHEADERS,PHDR)
  printf("Pool ID")
  for(phdrindex=1;phdrindex<=phdrcount;phdrindex++)
    printf(",%s",PHDR[phdrindex])
  printf("\n")
  for(pindex=1;pindex<=poolcount;pindex++) {
    printf("%s",poolids[pindex])
    for(phdrindex=1;phdrindex<=phdrcount;phdrindex++) {
      if(PHDR[phdrindex]=="Deep-Scrub: Average") {
        if(POOLEVENT[poolids[pindex]]["Deep-Scrub: Count"])
          printf(",%0.6f",POOLEVENT[poolids[pindex]]["Deep-Scrub: Total"]/POOLEVENT[poolids[pindex]]["Deep-Scrub: Count"])
        else
          printf(",")
      } else
        printf(",%s",POOLEVENT[poolids[pindex]][PHDR[phdrindex]])
    }
    printf("\n")
  }
}


