#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

PROJECT=${1:-vincent-de-saboulin-lab}

KEYFILE="${DIR}/keyfile.json"
if [ ! -f ${KEYFILE} ] && [ -z "$KEYFILE_CONTENT" ]
then
     logerror "ERROR: either the file ${KEYFILE} is not present or environment variable KEYFILE_CONTENT is not set!"
     exit 1
else 
    if [ -f ${KEYFILE} ]
    then
        KEYFILE_CONTENT=`cat keyfile.json | jq -aRs .`
    else
        log "Creating ${KEYFILE} based on environment variable KEYFILE_CONTENT"
        echo -e "$KEYFILE_CONTENT" | sed 's/\\"/"/g' > ${KEYFILE}
    fi
fi

${DIR}/../../environment/sasl-ssl/start.sh "${PWD}/docker-compose.sasl-ssl.yml"

GCS_BUCKET_NAME=kafka-docker-playground-bucket-${USER}${TAG}
GCS_BUCKET_NAME=${GCS_BUCKET_NAME//[-.]/}

log "Doing gsutil authentication"
set +e
docker rm -f gcloud-config
set -e
docker run -i -v ${KEYFILE}:/tmp/keyfile.json --name gcloud-config google/cloud-sdk:latest gcloud auth activate-service-account --project ${PROJECT} --key-file /tmp/keyfile.json

log "Creating bucket name <$GCS_BUCKET_NAME>, if required"
set +e
docker run -i --volumes-from gcloud-config google/cloud-sdk:latest gsutil mb -p $(cat ${KEYFILE} | jq -r .project_id) gs://$GCS_BUCKET_NAME
set -e

log "Removing existing objects in GCS, if applicable"
set +e
docker run -i --volumes-from gcloud-config google/cloud-sdk:latest gsutil -m rm -r gs://$GCS_BUCKET_NAME/topics/gcs_topic-ssl
docker run -i --volumes-from gcloud-config google/cloud-sdk:latest gsutil -m rm -r gs://$GCS_BUCKET_NAME/topics/gcs_topic
set -e

log "########"
log "##  SASL_SSL authentication"
log "########"

log "Sending messages to topic gcs_topic"
seq -f "{\"f1\": \"This is a message sent with SASL_SSL authentication %g\"}" 10 | docker exec -i connect kafka-avro-console-producer --broker-list broker:9092 --topic gcs_topic --property value.schema='{"type":"record","name":"myrecord","fields":[{"name":"f1","type":"string"}]}' --property schema.registry.url=https://schema-registry:8081 --property schema.registry.ssl.truststore.location=/etc/kafka/secrets/kafka.client.truststore.jks --property schema.registry.ssl.truststore.password=confluent --property schema.registry.ssl.keystore.location=/etc/kafka/secrets/kafka.client.keystore.jks --property schema.registry.ssl.keystore.password=confluent --producer.config /etc/kafka/secrets/client_without_interceptors.config

log "Creating GCS Sink connector with SASL_SSL authentication"
curl -X PUT \
     --cert ../../environment/sasl-ssl/security/connect.certificate.pem --key ../../environment/sasl-ssl/security/connect.key --tlsv1.2 --cacert ../../environment/sasl-ssl/security/snakeoil-ca-1.crt \
     -H "Content-Type: application/json" \
     --data '{
               "connector.class": "io.confluent.connect.gcs.GcsSinkConnector",
               "tasks.max" : "1",
               "topics" : "gcs_topic",
               "gcs.bucket.name" : "'"$GCS_BUCKET_NAME"'",
               "gcs.part.size": "5242880",
               "flush.size": "3",
               "gcs.credentials.path": "/tmp/keyfile.json",
               "storage.class": "io.confluent.connect.gcs.storage.GcsStorage",
               "format.class": "io.confluent.connect.gcs.format.avro.AvroFormat",
               "partitioner.class": "io.confluent.connect.storage.partitioner.DefaultPartitioner",
               "schema.compatibility": "NONE",
               "confluent.topic.bootstrap.servers": "broker:9092",
               "confluent.topic.replication.factor": "1",
               "confluent.topic.ssl.truststore.location" : "/etc/kafka/secrets/kafka.connect.truststore.jks",
               "confluent.topic.ssl.truststore.password" : "confluent",
               "confluent.topic.security.protocol" : "SASL_SSL",
               "confluent.topic.sasl.mechanism": "PLAIN",
               "confluent.topic.sasl.jaas.config": "org.apache.kafka.common.security.plain.PlainLoginModule required  username=\"client\" password=\"client-secret\";"
          }' \
     https://localhost:8083/connectors/gcs-sink/config | jq .

sleep 10

log "Listing objects of in GCS"
docker run -i --volumes-from gcloud-config google/cloud-sdk:latest gsutil ls gs://$GCS_BUCKET_NAME/topics/gcs_topic/partition=0/

log "Getting one of the avro files locally and displaying content with avro-tools"
docker run -i --volumes-from gcloud-config -v /tmp:/tmp/ google/cloud-sdk:latest gsutil cp gs://$GCS_BUCKET_NAME/topics/gcs_topic/partition=0/gcs_topic+0+0000000000.avro /tmp/gcs_topic+0+0000000000.avro

docker run --rm -v /tmp:/tmp actions/avro-tools tojson /tmp/gcs_topic+0+0000000000.avro

docker rm -f gcloud-config
