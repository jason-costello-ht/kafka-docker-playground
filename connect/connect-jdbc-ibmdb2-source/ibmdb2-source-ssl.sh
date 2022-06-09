#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

# https://docs.docker.com/compose/profiles/
profile_control_center_command=""
if [ -z "$DISABLE_CONTROL_CENTER" ]
then
  profile_control_center_command="--profile control-center"
else
  log "🛑 control-center is disabled"
fi

profile_ksqldb_command=""
if [ -z "$DISABLE_KSQLDB" ]
then
  profile_ksqldb_command="--profile ksqldb"
else
  log "🛑 ksqldb is disabled"
fi

docker-compose -f ../../environment/plaintext/docker-compose.yml -f "${PWD}/docker-compose.plaintext.ssl.yml" ${profile_control_center_command} ${profile_ksqldb_command} ${profile_grafana_command} down -v --remove-orphans
log "Starting up ibmdb2 container to get db2jcc4.jar"
docker-compose -f ../../environment/plaintext/docker-compose.yml -f "${PWD}/docker-compose.plaintext.ssl.yml" ${profile_control_center_command} ${profile_ksqldb_command} ${profile_grafana_command} up -d ibmdb2

rm -f ${DIR}/db2jcc4.jar
log "Getting db2jcc4.jar"
docker cp ibmdb2:/opt/ibm/db2/V11.5/java/db2jcc4.jar ${DIR}/db2jcc4.jar

# Verify IBM DB has started within MAX_WAIT seconds
MAX_WAIT=2500
CUR_WAIT=0
log "⌛ Waiting up to $MAX_WAIT seconds for IBM DB to start"
docker container logs ibmdb2 > /tmp/out.txt 2>&1
while [[ ! $(cat /tmp/out.txt) =~ "Setup has completed" ]]; do
sleep 10
docker container logs ibmdb2 > /tmp/out.txt 2>&1
CUR_WAIT=$(( CUR_WAIT+10 ))
if [[ "$CUR_WAIT" -gt "$MAX_WAIT" ]]; then
     logerror "ERROR: The logs in ibmdb2 container do not show 'Setup has completed' after $MAX_WAIT seconds. Please troubleshoot with 'docker container ps' and 'docker container logs'.\n"
     exit 1
fi
done
log "ibmdb2 DB has started!"

log "Enable SSL on DB2"
# https://stackoverflow.com/questions/63024640/db2-in-docker-container-problem-with-autostart-of-ssl-configuration-after-resta
# https://medium.datadriveninvestor.com/configuring-secure-sockets-layer-ssl-for-db2-server-and-client-3b317a033d71
docker exec -i ibmdb2 bash << EOF
su - db2inst1
gsk8capicmd_64 -keydb -create -db "server.kdb" -pw "my_secret_password" -stash
gsk8capicmd_64 -cert -create -db "server.kdb" -pw "my_secret_password" -label "myLabel" -dn "CN=myLabel" -size 2048 -sigalg SHA256_WITH_RSA
gsk8capicmd_64 -cert -extract -db "server.kdb" -pw "my_secret_password" -label "myLabel" -target "server.arm" -format ascii -fips
gsk8capicmd_64 -cert -details -db "server.kdb" -pw "my_secret_password" -label "myLabel"
db2 update dbm cfg using SSL_SVR_KEYDB /database/config/db2inst1/server.kdb
db2 update dbm cfg using SSL_SVR_STASH /database/config/db2inst1/server.sth
db2 update dbm cfg using SSL_SVCENAME 50002
db2 update dbm cfg using SSL_SVR_LABEL mylabel
db2set DB2COMM=SSL,TCPIP
db2stop force
db2start
EOF

mkdir -p ${PWD}/security/
rm -rf ${PWD}/security/*

cd ${PWD}/security/
docker cp ibmdb2:/database/config/db2inst1/server.arm .

if [[ "$OSTYPE" == "darwin"* ]]
then
    # workaround for issue on linux, see https://github.com/vdesabou/kafka-docker-playground/issues/851#issuecomment-821151962
    chmod -R a+rw .
else
    # on CI, docker is run as runneradmin user, need to use sudo
    ls -lrt
    sudo chmod -R a+rw .
    ls -lrt
fi
docker run --rm -v $PWD:/tmp vdesabou/kafka-docker-playground-connect:${CONNECT_TAG} keytool -import -v -noprompt -alias myLabel -file /tmp/server.arm -keystore /tmp/client.jks -storepass 'confluent'
log "Displaying truststore"
docker run --rm -v $PWD:/tmp vdesabou/kafka-docker-playground-connect:${CONNECT_TAG} keytool -list -keystore /tmp/client.jks -storepass 'confluent' -v
cd -

docker exec -i ibmdb2 bash << EOF
su - db2inst1
db2 get dbm cfg|grep SSL
EOF

docker-compose -f ../../environment/plaintext/docker-compose.yml -f "${PWD}/docker-compose.plaintext.ssl.yml" ${profile_control_center_command} ${profile_ksqldb_command} ${profile_grafana_command} up -d

command="source ../../scripts/utils.sh && docker-compose -f ../../environment/plaintext/docker-compose.yml -f "${PWD}/docker-compose.plaintext.ssl.yml" ${profile_control_center_command} ${profile_ksqldb_command} ${profile_grafana_command} up -d"
echo "$command" > /tmp/playground-command
log "✨ If you modify a docker-compose file and want to re-create the container(s), run ../../scripts/recreate-containers.sh or use this command:"
log "✨ $command"

../../scripts/wait-for-connect-and-controlcenter.sh

# Keep it for utils.sh
# ${DIR}/../../environment/plaintext/start.sh "${PWD}/docker-compose.plaintext.ssl.yml"

log "List tables"
docker exec -i ibmdb2 bash << EOF
su - db2inst1
db2 connect to sample user db2inst1 using passw0rd
db2 LIST TABLES
EOF

# https://www.ibm.com/docs/en/db2/11.5?topic=dsdjsss-configuring-connections-under-data-server-driver-jdbc-sqlj-use-ssl
log "Creating JDBC IBM DB2 source connector"
curl -X PUT \
     -H "Content-Type: application/json" \
     --data '{
               "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector",
               "tasks.max": "1",
               "connection.url":"jdbc:db2://ibmdb2:50002/sample:retrieveMessagesFromServerOnGetMessage=true;sslConnection=true;sslTrustStoreLocation=/etc/kafka/secrets/client.jks;sslTrustStorePassword=confluent;sslTrustStoreType=JKS;",
               "connection.user":"db2inst1",
               "connection.password":"passw0rd",
               "mode": "bulk",
               "topic.prefix": "db2-",
               "errors.log.enable": "true",
               "errors.log.include.messages": "true"
          }' \
     http://localhost:8083/connectors/ibmdb2-source/config | jq .

# 2022-06-09-11.07.54.306715+000 I301880E471           LEVEL: Error
# PID     : 17357                TID : 140472450279168 PROC : db2sysc 0
# INSTANCE: db2inst1             NODE : 000
# APPHDL  : 0-17
# HOSTNAME: ibmdb2
# EDUID   : 26                   EDUNAME: db2agent () 0
# FUNCTION: DB2 UDB, common communication, sqlccMapSSLErrorToDB2Error, probe:30
# MESSAGE : DIA3604E The SSL function "gsk_secure_soc_init" failed with the 
#           return code "407" in "sqlccSSLSocketSetup".

# The return code 407 means the label specified by ssl_svr_label can not be found in the key file specified by ssl_svr_keydb. Since DB2 server does not find the label, 
sleep 5

log "Verifying topic db2-PURCHASEORDER"
timeout 60 docker exec connect kafka-avro-console-consumer -bootstrap-server broker:9092 --property schema.registry.url=http://schema-registry:8081 --topic db2-PURCHASEORDER --from-beginning --max-messages 2

