HISTORY AND AUTHORS

* (C) 2009 by Alexandre Dumont
  Some simple scripts were initially published by Alexandre Dumont
  on his blog, and discussed by him and some commenters.
  See his original posts:
  * http://adumont.serveblog.net/2009/07/21/virtualbox-smf/
  * http://adumont.serveblog.net/2009/09/01/virtualbox-smf-2/
* (C) 2010-2012 by Jim Klimov, JSC COS&HT
  One of the "heavily upgraded" versions of these scripts was written
  by Jim Klimov, JSC COS&HT (Center of Open Systems and High Technologies)
  * It was initially published on VirtualBox forum as a topic
    "[Free as in beer] SMF service for VirtualBox VM's"
    http://forums.virtualbox.org/viewtopic.php?f=11&t=33249
  * Currently published as http://vboxsvc.sourceforge.net/

INTRODUCTION

Like many others, I wanted to run some VMs all the time regardless
of host reboots. And on Solaris/OpenSolaris hosts this is facilitated
by SMF services.

Almost a year ago Alexandre Dumont published his SMF method script
and manifest, and they allowed to do just that: register each VM
as an instance of the SMF service and enable or disable it.
It also allowed management of VMs owned by a non-root user (via
SMF service credentials) and, of course, SMF allows to set up
dependencies between VMs, resources and other services.
Many different follow-up scripts were developed and published on the
basis of Alexandre's code and explanations, and this one among them.

Over the past months I've used and extended this service, and published
"release-0.09" (2010-07-28) on VirtualBox forum with features including:
* to enable management of paused VMs,
* savestate and restore the VMs (i.e. on service disable/enable),
* run certain VMs with a tweaked NICE priority,
* reboot VMs gracefully via acpibutton-poweroff-poweron actions,
  or ingracefully via reset action,
* monitor the VM state according to VirtualBox (i.e. aborted, saved, etc.)
  and appropriately reflect this in SMF service state (cause maintenance
  or offline state for SMF service instance), or start up the VM,
** can count how many aborted states there were over the past X seconds
  and cause maintenance for a frequently failing VM (i.e. when the NFS
  server with its virtual disk is down, etc.),
* a number of command-line modes for the manifest script, including the
  ability to save VM state, restart it with a GUI mode for manual
  maintenance, and when you're done - save state again and the VM
  will be managed by its SMF service again,
* Moderately-tested hooks to call external scripts which can poll the VM's
  services to see if it is alive inside.

Updates in release 0.11 (2010-08-24) as a difference from previously published
version 0.09:
* Add processing for VBox empty state as a temporary error (retry next cycle),
* Added a flag to cause all 'offline' attempts to actually cause 'maintenance',
* Use `id` invokations good for both OpenSolaris and Solaris 10,
* add more definite dependencies for SMF service startup (milestone multi-user,
  filesystems/local; nfs/client and autofs are optional - which means "required
  if enabled") as a result of debugging our occasional failures with VMs
  running off NFS storage,
** for users implementing iSCSI this should probably provide a template to
  require iSCSI clients to start before VMs.

Updates in release 0.12 (2010-12-07):
* Documentation from the forum post was converted into this README :)
* Script and XML manifest example remained the same

Updates in release 0.13 (2011-07-13):
* Added command-line parameters to more easily specify VM_NAME or SMF_FMRI
  URL when using the script "interactively"
* Moderately tested override of a timezone used to run the VM as compared
  to host TZ. NOTE: If the VM is executed as a local user and if that user's
  profile somehow manages to override the TZ setting, it will be of higher
  priority than this method's override. User-profile's TZ will be used then.

Updates in release 0.14 (2011-11-23) are mostly cosmetic:
* Fixed long sleep()s into a series of 1-second sleeps, so that break
  signals are processed more quickly and service offlining happens faster.
* Some typo fixes and indentation fixes.
* Some implicitly hardcoded default values are now explicitly set.

Updates in release 0.15 (2012-01-30):
* "Unspecified" timezones may be not only an empty string, but also a couple
  of double-quotes (""). Catch couples of single-quotes too, for good measure.
  Generally caught in getproparg() routine.
* Detect if ZFS is used for backend storage (config files, VM disk files,
  snapshots) and try to create snapshots before starting/after stopping svc.
  This feature is DISABLED BY DEFAULT as to not waste space on your disks.
  It can be enabled with commands like these - for all VMs...:
  # svccfg -s vbox setprop vm/zfssnap_flag = boolean: true
  ...or for individual VMs: 
  # svccfg -s VM_NAME setprop vm/zfssnap_flag = boolean: true
  Cleaning up (removing obsolete snapshots) is the user's quest and out of
  vboxsvc's scope. You can try adapting zfs-auto-snap service's cleanup...
* Added command-line options to execute zfssnap, graceful/ungraceful poweroff,
  and a timeout-override option to poweroff and reboot command-line methods.

Updates in release 0.16 (2012-04-15):
* Generation of timestamps (current time or file modtime) is now a function
  that can be performed by calling either gdate or perl (slower). If neither
  is available, an error return code is set and a zero text value is output.
* Added command-line option to execute "dirlist" which reports all FS paths
  which are known to be related to the VM and would be ZFS-snapshotted.
* Timestamped infos for logging are now all in UTC (was mixed).
* Script now exports LANG=C LC_ALL=C to ensure english text from external
  things that it calls.
* Added an SMF manifest for a dummy service to optionally delay the VBOX
  service startup just after the host OS has booted.
* The SMF start method now has an option to wait for a defined timeout or
  until it detects that the VM began providing its services (using the
  KICKER monitoring hooks).
* Parse the KICKER monitoring hook parameters to "unescape" space chars.
* If a VM instantly failed to start, don't spawn the KICKER loop but fail
  the SMF instance instead.
* Clarified some comments and log-reports (i.e. report the stop timeouts)
* Try to survive 'svcadm refresh' which can seem like SMF offlining.

Updates in release 0.17 (in development):
* The getState() routine (i.e. the status command-line option) now checks
  results of the monitoring hook if configured (outputs test results, but
  does not influence return code), and returns more "ps" listing info.
* Added command-line action "vmsvccheck" to run the monitoring hook script
  if configured for the VM, and return its result code.

All thinkable behaviors and variables have been parametrized with SMF
service properties (group "vm/" or system props in groups "start/",
"stop/", etc.), and properties not defined at the instance level
(i.e. "svc:/site/xvm/vbox:VM_NAME") will be queried from the common
service level (i.e. "svc:/site/xvm/vbox").

Feel free to test this in your environment, and please report back
whether this worked well or not, or what can be fixed/improved.
Patches are welcome ;)

Hopefully this would not ruin your system, but beware that some
PID- and LOCK-files are used: created and removed. Some of this
activity can be enabled or disabled per-instance, any filenames
used can be hardwired into SMF properties (must be unique!).
See comments in XML manifest for more details.

Hope this helps,
//Jim Klimov



SOFTWARE, PACKAGING AND USAGE OVERVIEW

I was trying to put together a howto for some time, but the scripts 
evolved too fast to document single-handedly, so I dropped those 
attempts. Can try to summarize them here as a starter, though.

But probably the best documentation (at least most up-to-date) 
is the code and the lots of embedded comments, hopefully readers 
would find them readable and clean :)

Here we go with a mostly SMF-oriented part of the howto.

1) "COSvboxsvc" Overview

This updated "COSvboxsvc" comes as an SVR4 package file, and as 
a tarball with a couple of files - "method script + xml manifest".

Package file contains the same two important files plus some
SVR4 packaging metadata to streamline script-version updates,
and to keep track that the script is indeed installed on purpose
in a certain (Open)Solaris local zone. It also declares a package
dependency on SUNWvbox package to avoid automated installations 
wherever VirtualBox software is not installed.

Either way it can be used for running VMs in global or local
zones, owned (and executed) by "root" or less privileged users.

Presumably, if you have set up the VM to do whatever you want
from under the "/opt/VirtualBox/VirtualBox" GUI - setting up
all needed RBAC and filesystem permissions, unique MAC addresses
or console RDP ports, firewall rules or whatever else can limit
your VM's usability, this script can manage such VM if executed
with the same credentials via SMF.

I've run it only with Solaris 10 (updates 6 and 8) and OpenSolaris
SXCE ("Nevada") snv_117 thru snv_129 (x86 and x86_64). I haven't
tried it (or VirtualBox) with OpenSolaris Indiana (i.e. osol_b134),
OpenIndiana/illumos, Solaris 11 or any other distribution, so
I can't guarantee how it goes there.

As far as I know, it is now "mauvais ton" to run programs (including
shell) as a root, so all root-executed command lines should instead
be prefixed with "pfexec" on systems where that is available, 
while the user's interactive shell is unprivileged. Sun docs 
formulated this as "become superuser or assume an equivalent role".
In favor of backward-compatibility, my examples below assume that
the current user is root, as denoted by the "#" character in example
shell prompts.

Now, while the VM processes can be executed as an unprivileged user,
it takes a certain set of Solaris privileges to control an SMF service.
For this reason, the SMF method script for a VM running with credentials
of a non-root user can not (by default) change state of its own SMF
service instance (i.e. to initiate "offline" state for a temporarily
failed service). If this happens, the method script tries to do its
best to cause an SMF "maintenance" state by making a special lockfile
in order to prevent subsequent restarts.

Proper privileges can be delegated to a user account via RBAC profiles.
See docs, i.e.:
* http://hub.opensolaris.org/bin/view/Community+Group+smf/faq
  chapter 2.1.

2) Installation

a) Package format, global zone:

    # gzcat COSvboxsvc-0.16.pkg.gz > /tmp/x
    # pkgadd -d /tmp/x -G

You probably want the -G flag. It doesn't block you from manually installing
the same package in a certain local zone where you'd use VirtualBox, but
it blocks automatic package propagation to those local zones which are
not expected to use and run VirtualBox. For us these zones are rare,
zero or one per machine (there is no definite/hardcoded limit though). YMMV.

To update the package you can simply remove the old version and install
anew, i.e.:
    # gzcat COSvboxsvc-0.16.pkg.gz > /tmp/x
    # pkgrm COSvboxsvc
    # pkgadd -d /tmp/x -G

A cleaner way is to use an admin file to overwrite an existing package,
i.e. one from LiveUpgrade:
    # gzcat COSvboxsvc-0.16.pkg.gz > /tmp/x
    # pkgadd -d /tmp/x -G -a /etc/lu/zones_pkgadd_admin

Also note that this package "depends" on SUNWvbox, so that should be
installed beforehand.

b) Package format, local zone: like in the global zone, but without the
"-G" flag, i.e.:
    # gzcat COSvboxsvc-0.16.pkg.gz > /tmp/x
    # pkgadd -d /tmp/x

c) Files: copy script to "/lib/svc/method/vbox.sh" and the XML manifest
file - to anywhere you can edit it.

The SVR4 package places it into the "/var/svc/method/..." tree so it
will be automatically imported after zone's reboot (updating the SMF
repository if needed - as determined by XML file's version tag),
but this is not a requirement if you plan to edit and import the
file manually anyway.

In local zones the "/lib" directory may be read-only. In this case you
can place the script elsewhere (say, "/opt/VirtualBox") and modify the
SMF manifest accordingly.

3) Working with SMF service

You'd best read up the original documentation. Some random pointers:
* Sun BigAdmin: http://www.sun.com/bigadmin/jsp/utils/PrintCustomPage.jsp?url=http%3A%2F%2Fwww.sun.com%2Fbigadmin%2Fcontent%2Fselfheal%2Fsdev_intro.jsp
* Sun Wiki: http://wikis.sun.com/display/BigAdmin/SMF+Short+Cuts
* Joyent Wiki: http://wiki.joyent.com/solaris:smf-manifest-recipes

3.1) OVERVIEW OF SOLARIS SMF

As an overview of what's relevant to COSvboxsvc: there is a concept of
a "service" and its "instances". 

a) Instances define some unique set of parameters ("properties") to run
a specific VirtualBox VM. At the very minimum, they point to VM name
(as spelled in "~/.VirtualBox/VirtualBox.xml" registry file) - as the
instance's name, and often point to the user account whose credentials
will be used to execute the VM. The same user should usually have access
rights (read and/or write) to the VM files and directories ;)

b) A service definition groups together the OS concept of several VirtualBox
VMs. It points, for example (via stop/start methods) to the "vbox.sh" script,
or defines start/stop timeouts, or lists default dependencies.

In our case the "service" is mostly a container of default configuration
settings - but this is not the only use of "services" in SMF (see docs for
discussion of different implementation of "smtp" service via "sendmail" or
"postfix" instances, for example of other uses). 

We can also define all of the parameters at the service level and they will
be inherited by instances if not defined at instance level - but, again,
this is not a generic SMF feature (vboxsvc was specifically coded to do
this inheritance).

As may be outlined below, and is best described in code, many features
(particularly those which deal with lock files) can be enabled or
configured (i.e. to use definite filenames), for example to avoid some
sort of DoSing or other security flaws with the default configuration
(a well-known static config may fall prey to script-kiddies). Customized
configuration provides a weak defense against that, but one thing for
certain: these and similar properties, if configured, should be defined
at the instance level. The same lock-file name should not be used for
each VM, as inherited from service-level properties.

NOTE: most properties also have defaults hard-coded or evaluated during
"vbox.sh" execution. For example, if lock-file names are not defined in
SMF properties, they will be generated based on VM instance name.

c) You can start services. This checks all dependencies, and if satisfied,
executes the start method as defined in SMF. In our case, run "vbox.sh start":
    # svcadm enable VM_NAME

d) You can stop services. In our case, this calls "vbox.sh stop" which,
by default, saves VM state to disk for a quick restart (not VM reboot -
if all goes ok) afterwards.
    # svcadm disable -st VM_NAME

The "-s" flag causes "svcadm" to wait for the stop method to complete
before returning to shell.
The "-t" flag causes this disablement to be temporary. If the service
was previously "enabled" by svcadm, it will restart when the OS (or
local zone) reboots.

e) You can restart services. This is not often useful in our case,
except to check (via log files) that the framework is set up correctly,
or to apply new SMF properties. I use this a lot during development,
so I also present how to monitor the log file :)
    # tail -f /var/svc/log/site-xvm-vbox\:VM_NAME.log &
    # svcadm restart VM_NAME

f) You can view and modify the service (or instance) properties.
There are several ways: command-line snippets with svccfg or its
shell-like interface with the same keywords, and XML-file edition
and import. The XML file which describes all attributes of the
service and its instances (like the one provided with this package,
but without good comments) can be exported from the running system,
edited and imported back into the system.

=== Interactive modification of SMF service and instance definitions
"svccfg" interface is mostly oriented for shell-like execution (run it
and type "help"), but many of its commands can also be used as command-line
constructs for single-command actions.

Two examples below show how to set individual properties for service or
instance levels with command-line:
    # svccfg -s vbox setprop vm/offline_is_maint = true
    # svccfg -s VM_NAME setprop vm/restart_saved_vm = true

For individual VMs (instances) you can override existing settings or
add some dependencies, etc. This often requires you to do some research
and define correct additional "property groups" and then define whichever
properties you need at the instance level.

For example, to set SMF timeouts, you need to add the "start" and "stop"
property groups with type "framework", and then define and set some property
values in this group:
    # svccfg -s VM_NAME addpg start framework
    # svccfg -s VM_NAME addpg stop framework
    # svccfg -s VM_NAME setprop start/timeout_seconds = count: 120
    # svccfg -s VM_NAME setprop stop/timeout_seconds = count: 0
NOTE: A zero timeout value denotes absence of required timeout limitation.
In this case, the VM can stop for as long as it takes to do properly,
unless the OS is in a critical state like shutting down, and causes
the VM process to be killed in some other way.

NOTE: Some versions of SMF may have defined timeouts as "integer", others 
as "count". See your error logs or other services to determine which type 
is good for your OS.

NOTE: Some versions of SMF may require all relevant "start/" and "stop/"
values to be defined at one SMF level; i.e. if you set a custom value for
"stop/timeout_seconds" at the instance level, you must also copy other 
values from the service level. Otherwise you might see such effects as 
"undefined" method scripts in the SMF instance logs, i.e. messages like this
when stopping the service instance (i.e. "svcadm disable -st VM_NAME"):
    # tail /var/svc/log/*VM_NAME*
    ...
    [ Jan 17 16:30:29 Stopping because service disabled. ]
    [ Jan 17 16:30:29 Method property 'stop/exec is not present. ]
The SMF service would seen to become offline instantly, while in fact the
method script is never called, the VirtualBox VM process is never stopped 
and the VM continues working uninterrupted.

If your system shows such behavior, a somewhat bulky workaround is to redefine 
all "stop/*" ("start/*") settings at the instance level as soon as you define 
any custom value. For example:

1) Test if your VM's service instance (called svc:/site/xvm/vbox:VM_NAME) 
has custom values for SMF "stop" framework:
# svccfg -s VM_NAME listprop | grep stop/
stop/timeout_seconds               count    300

2) Test if stops work or fail:
# time svcadm disable -st VM_NAME
real    0m0.010s
user    0m0.001s
sys     0m0.003s
### That was way too quickly for a proper stop!

# tail /var/svc/log/*VM_NAME*
...
[ Jan 17 16:30:29 Stopping because service disabled. ]
[ Jan 17 16:30:29 Method property 'stop/exec is not present. ]

3) List the SMF-service-level framework parameters:
# svccfg -s svc:/site/xvm/vbox listprop | grep stop/
stop/type                                  astring  method
stop/exec                                  astring  "/lib/svc/method/vbox.sh stop"
stop/timeout_seconds                       count    220

4) Redefine all missing settings for your VM (note the quoting for parameters 
with spaces):
# svccfg -s VM_NAME setprop stop/type = astring: method
# svccfg -s VM_NAME setprop stop/exec = astring: '"/lib/svc/method/vbox.sh stop"'
# svcadm refresh VM_NAME
# svccfg -s VM_NAME listprop | grep stop/
stop/timeout_seconds               count    300
stop/type                          astring  method
stop/exec                          astring  "/lib/svc/method/vbox.sh stop"

5) Reenable the service instance 
(NOTE: this might suspend and restart your VM):
# svcadm enable VM_NAME
# tail -f /var/svc/log/*VM_NAME*
...

In general, whenever you change (and apply/SMF-refresh) any settings, do test
that they work on YOUR system before relying that they "should just work" :)

=== Predefined modification of SMF service and instance definitions
SMF service definitions can be genreally distributed as structured XML
files, and an example XML definition for VirtualBox SMF services (and
detailed comments) comes along with this package.

For XML-file manipulation of existing services, you do something simple 
like this:
    # svccfg export vbox > /tmp/vbox-svc.xml
    # vi /tmp/vbox-svc.xml
    ...
    # svccfg validate /tmp/vbox-svc.xml
    # svccfg import /tmp/vbox-svc.xml

You're encouraged to use the XML file approach to define additional new
VM instances. The XML file provided with the package contains all defined
properties (as processed by current script version) with explanations and
comments.

It also contains a disabled instance called "VM_NAME" which is intended
for copy-pasting for your VMs as a template. Most of the definable
properties are commented away in this block, so that service-level
or hardcoded/evaluated defaults would take place, and instance definitions
are quite short.

My typical VM instance definition looks like this:
   <instance name='my-desktop' enabled='true'>
      <method_context working_directory='/var/tmp'>
        <method_credential group='staff' user='jim'/>
      </method_context>
      <property_group name='vm' type='application'>
        <propval name='kicker_blockfile_enabled' type='boolean' value='true'/>
        <propval name='start_aborted_vm' type='boolean' value='true'/>
        <propval name='start_paused_vm' type='boolean' value='true'/>
        <propval name='stop_method' type='astring' value='savestate'/>
      </property_group>
   </instance>

g) Refresh services. After you change the service or instance properties
(via "svccfg" above), you should "refresh" each involved service instance.
AFAIK this copies the properties from a staging SMF repository to an active
one, and alerts service instances via a defined "refresh" method, if any.
In our case it is not defined, so defaults to ":true" and does nothing.

Now, most of the properties involve run-time configurations such as flag
file names or max abortion counts or the default stop method. If these
properties are used in the KICKER loop (see code), they are reloaded from
SMF on each cycle, so no actual refresh is needed, and ":true" is okay.

Nearly the only practical property which would require a service restart
is the execution user account (method_credential); you use "svcadm restart"
in this case anyway, to re-launch the VM process...

To refresh all instances after property changes, do something like:
    # for S in `svcs -a | grep vbox | awk '{ print $3 }'`; do
      svcadm refresh "$S"; done

4) Working without SMF service

While the "vbox.sh" script implements some SMF service requirements
(it allows usage as an SMF start/stop method, uses SMF error codes and 
properties for config, etc.), it can also be used as a command-line script. 

Usage for the current version can be viewed with the "-h" parameter:
    # /lib/svc/method/vbox.sh -h

To actually use the declared command-line methods on a specific VM,
you must export the "SMF_FMRI" environment variable with the complete
SMF service instance name, for example:
    # SMF_FMRI="svc:/site/xvm/vbox:VM_NAME" /lib/svc/method/vbox.sh startgui

Since release 0.13 you can also use a command-line switch to set SMF_FMRI
(if no value was previously defined - it won't overwrite existing values):
    # /lib/svc/method/vbox.sh -vm VM_NAME startgui
or
    # /lib/svc/method/vbox.sh -svc svc:/site/xvm/vbox:VM_NAME startgui
or
    # /lib/svc/method/vbox.sh -svc vbox:VM_NAME reset
The "-vm" flag appends the VM_NAME to the standard service base name, while
the "-svc" flag allows to set a full or shortcut SMF_FMRI URL.

Currently there are such command-line methods as:
* getstate|state|status - summarize VM state as returned by VirtualBox
  query state, and SMF instance state.
* reboot [ifruns] - try to gracefully reboot the VM [if it's currently running]
  This will attempt methods: acpipowerbutton -> poweroff -> reset -> start
* poweroff - try to gracefully "poweroff" the VM (acpipowerbutton -> poweroff)
* reset - try to quickly reset the VM
* startgui - save the VM state, and restart it with the GUI-mode VirtualBox
  (in VNC console to the headless host servers, in my case). If all goes OK,
  the VM resumes with the graphical VM console.
  You should test this before production, because this may lead to aborted
  VMs, i.e. if X11 is under-configured on a specific host system.
  When you're done with the graphical access to the VM, go to its window
  menu and select "Machine / Close / Save state".
  When the VM is saved, the command-line-mode "vbox.sh" script exits, and
  the VM resumes as an SMF service instance automatically.
** I confess this has failed on me more than once on some hosts (usually
   too minimized to run VNC and X11 in a stable manner), but also worked
   conveniently and quite well on many other hosts.
** Beside inadequately installed X11, there may also be "xhost" access right
   problems. You're encouraged to test with some programs like "xcalc" or
   "xterm" before risking to abort your VM due to X11 under-configuration;
   especially if your VM runs with the credentials of a different user ID!
* zfssnap - make a snapshot of all directories that contain VM's resources
  and are ZFS datasets.
* dirlist - list the directroies with VM resoures and relevant SMF settings.

Hopefully this is all the generic info there is to say about vboxsvc
and SMF services, and actualized details - such as property names, types
and purpose - should be seeked in current code's/manifest's comments.
Maybe (no promise) that will also be explicitly documented in a later
post...


TROUBLESHOOTING

Q1) SMF service exits quickly but the VM in fact continues working, or
    SMF service starts quickly but the VM process is not spawned

A1) If you defined the "stop/*" or "start/*" values for the VM's SMF instance,
    you may be hitting an SMF bug described above. You need to define all
    required properties of the execution methods (see above).

=====

Q2) A Windows XP VM refuses to shut down gracefully with "acpipowerbutton"

A2) If you use the XP VM remotely, the OS by default refuses to shut down if
    there are active non-console sessions. See this post for details:
    https://forums.virtualbox.org/viewtopic.php?f=2&t=24719&p=215403#p215403
    In short, try adding the following keys to your VM registry and reboot VM:
---
REGEDIT4
[HKEY_USERS\.DEFAULT\Control Panel\Desktop]
"AutoEndTasks"="1"
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows]
"ShutdownWarningDialogTimeout"=dword:00000001
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Error Message Instrument]
"EnableDefaultReply"=dword:00000001
---
    NOTE: Windows users don't get a warning message (i.e. "Shutting down 
    in 30 seconds): tasks were requested to end automatically, so Windows 
    should go down quickly.

=====

Q3) My VMs running in Solaris local zones don't seem to shut down properly
    when I halt the local zone.

A3) I've recently noticed that there is another feature to keep in mind when 
    hosting VMs in local zones: the "zoneadm -z ZONENAME halt" command
    terminates the zone's processes quickly, without going through proper 
    SMF shutdown procedures. For VM processes this quick termination would
    mean an abruptly aborted VM. Likewise for "zoneadm -z ZONENAME reboot".
    The proper way to stop or reboot a local zone gracefully is to run
    "zlogin ZONENAME init 0" or "zlogin ZONENAME init 6" accordingly. 
    Docs for Solaris 11 mention that they added a new action option -
    "zoneadm -z ZONENAME shutdown (-r)" for graceful shutdowns and reboots 
    of local zones, but this is not (yet) available in illumos/OpenIndiana.
    The default Solaris method script for stopping all zones (as when
    running "svcadm disable zones:default" in the global zone) tries the 
    graceful shutdown for 3/4 of the configured stop timeout time, and then 
    it tries the ungraceful shutdown for the remaining 1/4 of the time. 
    Finally, if this stop method does not finish stopping the zones, the
    SMF in the GZ would apparently kill the remaining zoneadmd processes 
    and their children as it would on all timeout failures.

    So, when hosting VMs in local zones, remember to use "zlogin...init..." 
    to stop or reboot a zone, and expand the "zones:default" SMF timeouts 
    to exceed the required and configured shutdown times of your VM service 
    instances. Also remember that if many VMs need to save-to-disk, this 
    would likely take longer in wall-clock time than your possible tests 
    of "how long does it take this VM to suspend?" executed for single 
    VMs at a time.

HTH,
//Jim Klimov

