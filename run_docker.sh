# arg $1 is docker image name. with docker-compose, default is name of folder holding docker-compose.yml
docker run --detach --name $1 --volume /usr/ipt:/srv/ipt --publish 80:8080 gbif/ipt
