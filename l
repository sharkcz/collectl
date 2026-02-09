commit d3dab6819dc92fa12da4616207c48fdbb1b86f21
Author: Laurence Oberman <loberman@redhat.com>
Date:   Sat Jun 28 10:38:36 2025 -0400

    Updated colplot to release 5.2.0  per request from
    Dan Horak

commit c1dcedc0fbcf161c4a074fecd24154013c8b3962
Author: Laurence Oberman <loberman@redhat.com>
Date:   Tue May 20 10:06:39 2025 -0400

    Add new Infiniband device name so stats get exposed for the new device
    names in /sys/class/infiniband/ibp202s0/ports/1/hw_counters
    Reported by youtive10 and fix suggested to add the new device name
    if ($devname=~/mthca|mlx4_|mlx5_|qib|hfi1_|ibp/)

commit 6be9301b958a50bd264f57907176b0f4d4609a02
Author: Laurence Oberman <loberman@redhat.com>
Date:   Thu Mar 27 18:06:19 2025 -0400

    Add an example collectl.spec file

commit 9e4cd81389acac303b1bb120277b59b28d5ab188
Author: Laurence Oberman <loberman@redhat.com>
Date:   Wed Mar 19 16:22:55 2025 -0400

    Versoon Change to 4.3.20 after adding the loop device support

commit 8f639ee8489525b67f2ef4758b8fcda152d8eee6
Author: Laurence Oberman <loberman@redhat.com>
Date:   Wed Mar 19 15:04:30 2025 -0400

    Added loop as a block device for detail disk

commit a4709b301b9acefa8d1163965aceff3f42c12b90
Author: Laurence Oberman <loberman@redhat.com>
Date:   Wed Oct 9 10:03:30 2024 -0400

    Added wl prefeix for wireless network interface names

commit 73e4f9e4d82797f906d05c913678231541a52a95
Author: Laurence Oberman <loberman@redhat.com>
Date:   Thu Jun 13 09:14:33 2024 -0400

    4.3.10  Jun 12 2024
      - Fixed an issue reported by Martin where nvme devices were not being aggregated in
     the summary display for disks
      - Tags will be properly updated now, I had missed that when I took this over

commit f63951f72215db9d7957f91ab9f9c32ccbe681d3
Author: Laurence Oberman <loberman@redhat.com>
Date:   Tue Jan 2 11:18:37 2024 -0500

    Version 4.3.9 with md added for disks

commit 471bc215ec366e960a1989c4da188b2493e24148
Author: Laurence Oberman <loberman@redhat.com>
Date:   Tue Aug 1 16:23:27 2023 -0400

    Added md devices to disk parse

commit b888504cef6582ba5f0a269af5a46b19c996a66c
Author: Laurence Oberman <loberman@redhat.com>
Date:   Tue May 30 14:37:21 2023 -0400

    Update README

commit b33c643b3e30e025bbd466e9dd7836b1e5046118
Author: Laurence Oberman <loberman@redhat.com>
Date:   Tue May 30 14:36:42 2023 -0400

    Update README

commit 42cd088d775d3f927b6c9daabb22c0136a1e05a4
Author: Laurence Oberman <loberman@redhat.com>
Date:   Mon May 1 17:24:30 2023 -0400

    Modified the INSTALL script to work with RHEL9+ that have no
    chkconfig

commit 802cd4123330d7ddbdc61d901dd07b9f8461e33f
Author: Laurence Oberman <loberman@redhat.com>
Date:   Tue Feb 7 13:53:05 2023 -0500

    Updated version numbers

commit 067f8de362479b9ec414aa5d7d8aa0d6d6c87630
Author: Laurence Oberman <loberman@redhat.com>
Date:   Tue Feb 7 13:46:19 2023 -0500

    Report from Martin Arlitt about missing Network interfaces so added those to formatit.ph

commit cd8a94b61f5700945af8f4e6a3fcd0e4ea18f1e2
Author: Laurence Oberman <loberman@redhat.com>
Date:   Wed Jan 25 17:21:32 2023 -0500

    Add the nvme native multipath devices filter to the collectl.conf
    "nvme\d+c\d+"

commit 2001864971f91999216daf091529f5aa47d69150
Author: Laurence Oberman <loberman@redhat.com>
Date:   Tue Nov 29 18:29:26 2022 -0500

    Version 4.3.6 with fix in sub vmstatInit where error check was removed

commit 625e2453842121519e9e5a38c283d02e72e2ed89
Author: Laurence Oberman <loberman@redhat.com>
Date:   Tue Nov 29 18:19:44 2022 -0500

    Removed the error check in sub vmstatInit
    It was erroneous and that option is seledom used.
    Reported-by: Bill Torpey <wallstprog@users.sourceforge.net>

commit 928e0a662a67b0c38f0d5ebacae3d28440d3e3f6
Author: Laurence Oberman <loberman@redhat.com>
Date:   Mon Nov 7 09:58:48 2022 -0500

    Added the tar file for colplot to our source tree

commit 221d0a683f5487b103973f00f8ccc45c80a3dd07
Author: Laurence Oberman <loberman@redhat.com>
Date:   Fri Oct 28 17:48:18 2022 -0400

    Released 4.3.5 with default rbd device support

commit 30ff18dc049d163d01599fee35226fa8e57ca5bc
Author: Laurence Oberman <loberman@redhat.com>
Date:   Fri Oct 28 17:44:27 2022 -0400

    Added default support for rbd (Rados block) disks to the default collectl.conf file
    DiskFilter = /hd[ab] | sd[a-z]+ |dm-\d+ |xvd[a-z] |fio[a-z]+ | vd[a-z]+ |emcpower[a-z]+ |psv\d+ |nvme\d+n\d+ |rbd\d+ /

commit a34a0f47c1c2f387e2660c496d87ed84b04a87c5
Author: Laurence Oberman <loberman@redhat.com>
Date:   Tue Aug 23 17:40:42 2022 -0400

    Add patch for dskopts=F to allow double digit precision on playback

commit f14c9b0ba7d1e272492ab95d84ed43af0b6c0815
Author: Laurence Oberman <loberman@redhat.com>
Date:   Tue Apr 5 09:01:16 2022 -0400

    Version change to 4.3.3

commit 517c19c94ae623eb7ab373edff1563328d03eb2b
Author: Laurence Oberman <loberman@redhat.com>
Date:   Fri Apr 1 11:52:02 2022 -0400

    Patch to fix IB collection in systems with multiple mellanox cards
    suggested-by: Gary Skouson
    
    The use of HCAName isn't right and should be HCAId, especially if you have mellanox ethernet and IB in the same box, the '0' or $i isn't going to work right. For example on one system, we have bonded ethernet on a mellanox ethernet card and a separate IB card, so /sys/class/infiniband shows two devices mlx5_2 and mlx5_bond_0.
    
    For the formatit.ph the logic isn't right. The $link comparison should be with "eq" not "=". I also think we need to chomp $link to remove the newline before the compare.

commit 8c37d5f9a64457b6e75f31d094503e4feb9808f0
Author: Laurence Oberman <loberman@redhat.com>
Date:   Wed Jan 12 11:57:39 2022 -0500

    Added specifics about version 4.3.2 and uploaded new version to Sourceforge

commit dc327fab45370c2f04bf174f8003a75b5134e7e8
Author: Laurence Oberman <loberman@redhat.com>
Date:   Fri Oct 8 13:20:22 2021 -0400

    Change version after taking over and fixing the buf with the last being called Version now 4.3.2

commit 2d68bd7d456c0f94066a0c999d07ed92d267e046
Author: Laurence Oberman <loberman@redhat.com>
Date:   Fri Oct 8 11:35:52 2021 -0400

    Deal with the bug where last was called in the perf_query code for Infiniband and was not in a loop https://sourceforge.net/p/collectl/discussion/696864/thread/fc58a31168/?limit=25#2f7c

commit 42450515addc328251e62c4182b3a609698d26dc
Author: Dan Horák <dan@danny.cz>
Date:   Wed Jun 19 09:39:06 2019 +0200

    import 4.3.1

commit 7e23c5ee7d8a0d193a0c414001f047ce4e5c24f1
Author: Dan Horák <dan@danny.cz>
Date:   Sun Dec 17 14:05:42 2017 +0100

    import 4.3.0

commit c1156cc22df16de7d7ce80520a0beea7259e98cc
Author: Dan Horák <dan@danny.cz>
Date:   Wed Jun 14 08:35:40 2017 +0200

    import 4.2.0

commit f4ac2c6dfba0ce35971e098d86cbede3fb3a11cd
Author: Dan Horák <dan@danny.cz>
Date:   Mon May 15 09:24:40 2017 +0200

    import 4.1.3

commit 13195fa36fdd65732306e86841b17cd8cdb559d1
Author: Dan Horák <dan@danny.cz>
Date:   Mon May 15 09:23:51 2017 +0200

    import 4.1.2

commit 2346c02ea650c4b5ee3ccaa50739b22ae309f4a1
Author: Dan Horák <dan@danny.cz>
Date:   Thu Oct 13 11:59:16 2016 +0200

    import 4.1.0

commit 64e963af0b456daa2cd8074e2dbc598aaa700105
Author: Dan Horák <dan@danny.cz>
Date:   Thu Oct 13 11:58:51 2016 +0200

    import 4.0.5

commit 11eb4b4dbe5055df08768a32af1738b3b52cdd47
Author: Dan Horák <dan@danny.cz>
Date:   Thu Oct 13 11:58:26 2016 +0200

    import 4.0.4

commit 4fe5bae216845467a692845ec88a140286434296
Author: Dan Horák <dan@danny.cz>
Date:   Thu Oct 13 11:57:45 2016 +0200

    import 4.0.2

commit 6d85f5088c889c5ebe38ba1a31fa276cbe1488d1
Author: Dan Horák <dan@danny.cz>
Date:   Thu Apr 9 11:12:39 2015 +0200

    import 4.0.0

commit 51358880848132a129ad5bf968630b91e9409f60
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 15 10:18:09 2014 +0200

    import 3.7.4

commit 10f57c30c953398fca7d14b92d49cc69acec0202
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 15 10:17:47 2014 +0200

    import 3.7.3

commit 4e7787c5ea5894df4d8f232942f858f2dd1d4745
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 15 10:17:15 2014 +0200

    import 3.6.9

commit aae572a91e835e020bb81e4782374b874dc67ccc
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 15 10:16:44 2014 +0200

    import 3.6.8

commit b2f2804f3769a1c6da38a12934bc30b8ead4b48e
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 15 10:16:19 2014 +0200

    import 3.6.7

commit 119a6ef57c4064fe1d6ed56fe4e7c698e1053b8e
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 15 10:15:57 2014 +0200

    import 3.6.5

commit 2fd94b17dc036dc44a2f507dac9cdd0bfd237aeb
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 15 10:15:29 2014 +0200

    import 3.6.3

commit a8979d149bc5aeb37d7d9d76892adfdd060c4965
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 15 10:14:54 2014 +0200

    import 3.6.1

commit 0f47653198860d4f3612a27845004ab8e98406c6
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 15 10:14:26 2014 +0200

    import 3.6.0

commit 62ddaed721fb320e5f72f7594f13424103c1fd62
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 15 10:14:02 2014 +0200

    import 3.5.1

commit 56bd47aa48671471c7eeda804a47ab3edd527f90
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 15 10:13:26 2014 +0200

    import 3.5.0

commit aef81872173ae8ce7bb64a3a2f068fc1199b9307
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 15:02:07 2010 +0200

    import 3.4.3

commit b03ab13187165bc619dfb41c9437800fd58a7543
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 15:01:45 2010 +0200

    import 3.4.2

commit 94ffcb2fc2cf25b00711c0898697e738a6c77d64
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 15:01:17 2010 +0200

    import 3.4.1

commit cff91da2e6baa0b8dc805b9092f4c20204a32b15
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 15:00:48 2010 +0200

    import 3.4.0

commit 61deac0bcf89ded889ae356f1aa310f5ad1fddc9
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:59:47 2010 +0200

    import 3.3.6

commit 6110cb80db17023e66c0effa41a27b711587967b
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:59:14 2010 +0200

    import 3.3.5

commit d69651074b9f607a9cfae92b5f33858dc8549183
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:58:36 2010 +0200

    import 3.3.4

commit 249eaea61ede3e258e4b408653b910ec9fb15977
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:58:08 2010 +0200

    import 3.3.2

commit 6d6f72c70a498916d0361a9b136fa018e55f4326
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:56:17 2010 +0200

    import 3.2.1

commit aa4e313ccd960740969f820f028549b7cfb6b68f
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:55:50 2010 +0200

    import 3.1.3

commit cfb9fef88945d4af9f792bdf445da453bb30005a
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:55:01 2010 +0200

    import 3.1.2

commit 30dc9ce8eee1ea26f8c93915f9d43ce99eab4f34
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:54:35 2010 +0200

    import 3.1.1

commit f2c6953a69e0e088873d43e2e02850b2af02229e
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:54:04 2010 +0200

    import 3.1.0

commit 50e6b80d446ecd68c6662ee5281db0da02ede3cd
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:53:33 2010 +0200

    import 3.0.0

commit 77b59db8806055c42834c29a88e98693b9fd0ab5
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:52:40 2010 +0200

    import 2.6.4

commit d0e4ce9112fcbe7bc5eed94079ac59d81996118e
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:51:43 2010 +0200

    import 2.6.2

commit 3d62dd07649b72d416e702a4e28ae5384fdbe276
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:48:59 2010 +0200

    import 2.5.1

commit e6aaf1ae0954e2fe0266b8b3e1bc61802357be77
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:47:49 2010 +0200

    import 2.5.0

commit 483b0b42b5e31a72bfeb7fc99136e06c1beaa38b
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:46:37 2010 +0200

    import 2.4.3

commit 1cd3324019d5cccf3d90cb030bd34aa9c7db1576
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:46:08 2010 +0200

    import 2.4.2

commit 0c635bb841faeaa8b261851d1825f7f40da7f1e9
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:45:41 2010 +0200

    import 2.4.1

commit d3ba7f5290e826decba0ec5abb100f7939eb2faa
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:45:15 2010 +0200

    import 2.4.0

commit 68fe478fef913fd3c85358c2458fa9d08d222055
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:44:49 2010 +0200

    import 2.3.4

commit fdc730dee91d438384cc34a28a1f168d6bead168
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:44:22 2010 +0200

    import 2.3.3

commit 4e8c98be61cdb0fc3d7cd78aa4fc7827eb683ea0
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:43:56 2010 +0200

    import 2.3.2

commit 352b465ed938a4307c8ca1807d4943bcb4eb562f
Author: Dan Horák <dan@danny.cz>
Date:   Mon Sep 13 14:42:53 2010 +0200

    import 2.3.1
