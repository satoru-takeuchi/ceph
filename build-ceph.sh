CEPH_VERSION=v15.2.12

# checkout ceph source
git checkout ${CEPH_VERSION}
git submodule update --init --recursive

# Install dependencies

apt-get update
./install-deps.sh

# build ceph packages

sed -i -e 's/WITH_CEPHFS_JAVA=ON/WITH_CEPHFS_JAVA=OFF/' debian/rules
sed -i -e 's/usr\/share\/java\/libcephfs-test.jar//' debian/ceph-test.install
rm debian/libcephfs-java.jlibs debian/libcephfs-jni.install debian/ceph-mgr-dashboard*
dpkg-buildpackage --build=binary -uc -us -j4    
rm ../*-dbg_*.deb ../*-dev_*.deb
mv ../*.deb ../
