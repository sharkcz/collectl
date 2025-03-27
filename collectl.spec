Name:           collectl
Version:        4.3.10
Release:        1%{?dist}
Summary:        A system performance monitoring tool

License:        GPLv3
URL:            http://collectl.sourceforge.net/
Source0:        %{name}-%{version}.src.tar.xz
BuildArch:      noarch
BuildRequires:  perl
Requires:       perl

%description
Collectl is a lightweight system monitoring tool that collects 
performance data for CPUs, memory, disks, networks, and more.

%prep
# Extract the source tarball in /tmp
mkdir -p /tmp/collectl-build
tar  hzxvf %{SOURCE0} -C /tmp/collectl-build

%build
# No explicit build step needed

%install
# Run the INSTALL script inside the extracted directory
cd /tmp/collectl-build/collectl-4.3.10-1.el9.x86_64
./INSTALL

# Ensure proper installation paths
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/share/man/man1
mkdir -p %{buildroot}/usr/share/collectl/util
mkdir -p %{buildroot}/etc/collectl
mkdir -p %{buildroot}/etc/init.d
mkdir -p %{buildroot}/usr/lib/systemd/system

# Move installed files to the appropriate locations
install -m 755 collectl %{buildroot}/usr/bin/collectl
install -m 644 collectl.conf %{buildroot}/etc/collectl/collectl.conf
install -m 644 collectl.conf %{buildroot}/etc/collectl.conf
install -m 775 envrules.std %{buildroot}/usr/share/collectl/envrules.std
install -m 775 formatit.ph %{buildroot}/usr/share/collectl/formatit.ph
install -m 775 gexpr.ph %{buildroot}/usr/share/collectl/gexpr.ph
install -m 775 graphite.ph %{buildroot}/usr/share/collectl/graphite.ph
install -m 775 hello.ph %{buildroot}/usr/share/collectl/hello.ph
install -m 775 lexpr.ph %{buildroot}/usr/share/collectl/lexpr.ph
install -m 775 misc.ph %{buildroot}/usr/share/collectl/misc.ph
install -m 775 statsd.ph %{buildroot}/usr/share/collectl/statsd.ph
install -m 775 UNINSTALL %{buildroot}/usr/share/collectl/UNINSTALL
install -m 775 client.pl %{buildroot}/usr/share/collectl/util/client.pl
install -m 775 vmstat.ph %{buildroot}/usr/share/collectl/vmstat.ph
install -m 775 vmsum.ph %{buildroot}/usr/share/collectl/vmsum.ph
install -m 775 vnet.ph %{buildroot}/usr/share/collectl/vnet.ph
install -m 775 initd/collectl %{buildroot}/etc/init.d/collectl
install -m 775 service/collectl.service %{buildroot}/usr/lib/systemd/system

%files
/usr/bin/collectl
/etc/collectl/collectl.conf
/etc/collectl.conf
/usr/share/collectl/envrules.std
/usr/share/collectl/formatit.ph  
/usr/share/collectl/gexpr.ph  
/usr/share/collectl/graphite.ph  
/usr/share/collectl/hello.ph  
/usr/share/collectl/lexpr.ph  
/usr/share/collectl/misc.ph  
/usr/share/collectl/statsd.ph  
/usr/share/collectl/UNINSTALL  
/usr/share/collectl/util/client.pl  
/usr/share/collectl/vmstat.ph  
/usr/share/collectl/vmsum.ph  
/usr/share/collectl/vnet.ph
/etc/init.d/collectl
/usr/lib/systemd/system/collectl.service


%post
echo "Collectl has been installed successfully!"

%clean
rm -rf /tmp/collectl-build

%changelog
* Thu Mar 27 2025 Your Name <your.email@example.com> - 4.3.10-1
- Initial RPM package for Collectl 4.3.10
