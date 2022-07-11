# Simply copy from letsencrypt symlink cert location, eg. 
#  fullchain.pem -> ../../archive/ipt.vtatlasoflife.org/fullchain5.pem
# which changes on each certs update, to a local file in the same directory.
cp /etc/letsencrypt/live/ipt.vtatlasoflife.org/fullchain.pem ipt.crt
cp /etc/letsencrypt/live/ipt.vtatlasoflife.org/privkey.pem ipt.key

# NOTE: it does not appear that we need separate certs for vtecostudies.org,
# since in docker-compose service:ipt CERT_NAME is 'ipt' and service:nginx DEFAULT_HOST
# is 'ipt.vtatlasoflife.org'. However, if we do, then do this:

cp /etc/letsencrypt/live/ipt.vtecostudies.org/fullchain.pem eco.crt
cp /etc/letsencrypt/live/ipt.vtecostudies.org/privkey.pem eco.key
