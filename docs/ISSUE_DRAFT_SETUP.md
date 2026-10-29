# Issue draft: Setup still launches on a fresh mkiosroot image (SM8850 / Xiaomi 17)

Ready to paste into `ShueiTsuki/data-a-live` (or link from a shorter UniXNU issue, #119 style).
Fill in the two [ ] links before posting. English, no serials, no tokens, no full logs.

---

**Title:** SM8850 (Xiaomi 17 / `pudding`) port: SpringBoard reaches the cover sheet but still launches Setup with `SetupDone` already true — is the decision gated on activation?

I'm porting to an **SM8850** device (Xiaomi 17, codename `pudding`; your device is `pandora`, same SoC
family). The kernel boots, iOS user space runs, and SpringBoard renders — I can walk the Setup pages
with taps injected from the kernel. What I cannot get past is **Setup itself**: it keeps launching even
though the preference that is supposed to skip it is already in the image.

Everything below is measured on hardware, not inferred.

**Stack.** ABL, `fastboot boot` of a shim payload (same lineage as `ios-fuxi`'s loader). Root is a
16 GiB pinned HFS+ image in `userdata` (`rd=ufsroot0`), built from the iPhone X **20H392** iPSW with
`mkiosroot.sh` and the `fuxi-stage-root.py` staging (3,140 cryptex links + `/private/var/keybags`).
Kernel is your patch series at **0262**; 0263–0295 (brightness/audio) are not in it.

**Where it gets to.** `exec SpringBoard` at 12.2 s. On a cold LaunchServices database the first
present is at **835 s** (lsd reseeding; upstream notes ~25 min), and on the second boot of the same
image it is **59 s**. So the lsd wall is behind us. 34 ms after the cover sheet presents:

```
[   59.115] |SpringBoard| Unbalanced calls to begin/end appearance transitions for
            <SBCoverSheetPrimarySlidingViewController: 0x10100d400>.
[   59.153] exec Setup
```

i.e. SpringBoard has presented the lock-screen layer and then, itself, starts Setup. Blocking Setup's
exec instead (`sweetnoexec=Setup`) leaves SpringBoard on the Apple logo forever, which is consistent
with it waiting for Setup rather than with any settings problem.

**The preference is there and it is correct.** Read back from the image
(`/private/var/mobile/Library/Preferences/com.apple.purplebuddy.plist`, owner `mobile:mobile`, mode
`0600`, 130-byte **binary** plist):

```
{SetupDone: true, SetupFinishedAllSteps: true, SetupVersion: 11, daemonizeNeedsToRun: false}
```

`com.apple.purplebuddy.notbackedup.plist` has all six mini-buddy flags `false`, and
`com.apple.managedconfiguration.notbackedup.plist` has
`LockdownActivationIndicatesCloudConfigurationAvailable = false`. Those five files are written at the
same paths, by the same owner and in the same format as `ios-fuxi/tools/sweet-root-tweaks.py` — I
diffed my tweak script against it **key for key** and the Setup section is identical. So whatever is
different is not the keys.

**The one substantive difference I found** is activation. In your image the
`com.apple.mobileactivationd` launchd job is the real daemon with its `MachServices`. In mine it is a
stub:

```
com.apple.mobileactivationd | ProgramArguments: ['/usr/bin/true'] | MachServices: 0
```

because the real `mobileactivationd` aborts at 12.8 s with `sig 5`, repeatedly, inside
`copyReverseProxyDictionary` (`CRASH mobileactivation sig 5 code 0x600000001 sub 0x100cb13bc`), and
with its MachServices registered it drags lsd/SpringBoard down with it. `sweetnoexec=mobileactivationd`
is not a substitute: the process is stopped but the service is still registered, and clients block.

**Questions**

1. Do you read this as an **activation gate**? Your notes say the activation data packet is skipped
   because the `mobileactivationd` system container does not exist and activation goes through the
   ADT's security-status attribute (local Hactivation). On your device, was the real daemon *running*
   in that state (so activation answers "Activated"), or was there effectively no activation service
   at all? I would like to know whether putting the real daemon back — after fixing the
   `copyReverseProxyDictionary` abort, or seeding whatever makes it answer locally — would make
   SpringBoard skip Setup on its own.
2. If it is *not* activation, is there any other marker in your image that SpringBoard's setup
   decision reads? I can dump any file of the running system into the kernel log
   (`pandora_cat=<path>:<seconds>`) or compare an arbitrary path list against yours — tell me what to
   check and I'll report the bytes back.

**What I can do in return:** this device is free to boot test images at will (it comes back to Android
by holding power, and I have full partition backups), and I can produce any boot log, file dump or
framebuffer capture you want. A short write-up with the build steps and every measurement so far is in
`https://github.com/yechenan/pudding-ios` (docs are in Chinese; I can translate anything on request).
