sudo curl -o /etc/yum.repos.d/isc-bind-epel-10.repo \
  https://copr.fedorainfracloud.org/coprs/isc/bind/repo/epel-10/isc-bind-epel-10.repo

dnf --showduplicates list bind