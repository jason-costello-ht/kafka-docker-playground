#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

${DIR}/../../environment/plaintext/start.sh "${PWD}/docker-compose.yml" -a -b

log "Starting producer"
docker exec -i client-dotnet bash -c "dotnet DotNet.dll broker:9092 dotnet-basic-producer"

Control Center is reachable at [http://127.0.0.1:9021](http://127.0.0.1:9021])