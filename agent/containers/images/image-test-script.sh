#!/bin/bash

# A demonstration of how to use pbench-tool-meister-start with an existing
# Redis server, and one or more remote
export CONTROLLER=$(hostname -f)

verified=""
while [ -z "$verified" ]
do
    read -p "Specify distribution to test (or press 'ENTER' for default 'centos-8'): " DISTRO
    if [ -z "$DISTRO" ]
    then
        DISTRO="centos-8"
    fi

    read -p "Specify image tag to test (or press 'ENTER' for default 'a933ae45e'): " TAG
    if [ -z "$TAG" ]
    then
        TAG="a933ae45e"
    fi

    printf -- "Pulling tool-data-sink image to test...\n"
    verified=$(podman pull quay.io/pbench/pbench-agent-tool-data-sink-$DISTRO:$TAG 2> /dev/null)

    if [ -z "$verified" ]
    then
        printf -- "Distro/tag combination could not be found, please try again.\n\n"
    else
        printf -- "Complete!\n\n"
    fi
done

badhost=true
while [ "$badhost" == true ]
do
    read -p "Specify redis host (or press 'ENTER' for default '$CONTROLLER'): " REDIS_HOST
    if [ -z "$REDIS_HOST" ]
    then
        REDIS_HOST=$CONTROLLER
    fi
    ping_first=$(ping -c 1 -W 1 ${REDIS_HOST} 2>&1 | grep 'Name or service not known')
    ping_second=$(ping -c 1 -W 1 ${REDIS_HOST} 2>&1 | grep '100% packet loss')
    if [ -n "$ping_first" ] || [ -n "$ping_second" ]
    then
        printf -- "Host specified either does not exist or is unreachable, please try again:\n"
    else
        badhost=false
    fi
done

badport=true
while [ "$badport" == true ]
do
    read -p "Specify redis port (or press enter for default port '17001'): " REDIS_PORT
    if [ -z "$REDIS_PORT" ]
    then
        REDIS_PORT=17001
    fi
    if [ "$REDIS_PORT" -eq "$REDIS_PORT" 2> /dev/null ]
    then
        badport=false
    else
        printf -- "Value inputted was not numeric, please retry\n"
    fi
done
export REDIS_HOST REDIS_PORT
export PBENCH_REDIS_SERVER="${REDIS_HOST}:${REDIS_PORT}"

function wait_keypress {
    echo "Press any key to continue"
    while [[ true ]]; do
        read -t ${1} -n 1
        if [[ ${?} = 0 ]]; then
            return 0
        else
            echo "waiting for the keypress"
        fi
    done
}

clear

printf -- "We will now begin the guided pbench image test process. \n\n\n"

wait_keypress 120

# If somebody wants to write their own pbench-tool-meister-start, great, then
# that person can change the assumption on where the persistent volume is for
# the Tool Data Sink, and how the "sysinfo", "init", and "end" commands
# operate with respect to data storage.

export pbench_run=/var/tmp/test-run-dir
rm -rf ${pbench_run}
mkdir ${pbench_run}
printf -- "${pbench_run}\n" > ${pbench_run}/.path
export pbench_log=${pbench_run}/pbench.log

printf -- "\n\nThe benchmark run directory will be found inside:\n\n"

find ${pbench_run} -ls

wait_keypress 120


# Register tools

printf -- "\nNow, let's pick hosts to collect data from, as well as which tools we wish to register for that host.\n\n"

wait_keypress 120

anotherhost=y
while [ $anotherhost == "y" ]
do
    read -p "Hostname (or press 'ENTER' for default '$CONTROLLER'): " hostvar
    if [ -z "$hostvar" ]
    then
        hostvar=$CONTROLLER
    fi
    ping_first=$(ping -c 1 -W 1 ${hostvar} 2>&1 | grep 'Name or service not known')
    ping_second=$(ping -c 1 -W 1 ${hostvar} 2>&1 | grep '100% packet loss')
    if [ -n "$ping_first" ] || [ -n "$ping_second" ]
    then
        printf -- "Host specified either does not exist or is unreachable, please try again:\n"
    else
        echo $hostvar >> ${pbench_run}/remotes.lis
        read -p "Another host? (y/n)" anotherhost
    fi
done
printf -- "\nDone selecting hosts:\n"
cat ${pbench_run}/remotes.lis
printf -- "\nNow to select tools.\n\n"

# Register the specified tools, will be recorded in
# ${pbench_run}/tools-v1-default
anothertool=y
while [ $anothertool == "y" ]
do
    read -p "Tool name (type 'help' to see options): " tool
    if [ -z "$tool" ]
    then
        printf -- "Tool name empty. Please write a tool name.\n"
    else
        if [ $tool == "help" ]
        then
            printf -- "\nAvailable tools:\n"
            python3 -c "import sys, json; meta = json.load(open(sys.argv[1])); print('  Transient:', *[f'\t{tool}' for tool in meta['transient'].keys()], '  Persistent:', *[f'\t{tool}' for tool in meta['persistent'].keys()], sep='\n')" /opt/pbench-agent/tool-scripts/meta.json
        else
            printf -- "\npbench-register-tool --name=${tool} --remotes=@${pbench_run}/remotes.lis\n"
            pbench-register-tool --name=${tool} --remotes=@${pbench_run}/remotes.lis
            sleep 1
            read -p "Another tool? (y/n)" anothertool
        fi
    fi
done
printf -- "\nDone registering tools.\n\n"
ls -lR ${pbench_run}/tools-v1-default

printf -- "\n\n"
wait_keypress 120


# Start Tool Meister containers on remote host

printf -- "\n\nNow please start the Tool Meister container on the specified host...\n\n\t$ podman run --name pbench-agent-tool-meister \\ \n\t\t--network host --ulimit nofile=65536:65536 --rm -d \\ \n\t\t-e REDIS_HOST=${REDIS_HOST} \\ \n\t\t-e REDIS_PORT=${REDIS_PORT} \\ \n\t\t-e PARAM_KEY=tm-default-\$(hostname -f) \\ \n\t\t-e _PBENCH_TOOL_MEISTER_LOG_LEVEL=debug \\ \n\t\tquay.io/pbench/pbench-agent-tool-meister-${DISTRO}:${TAG}\n\n"

wait_keypress 120


# Start the Tool Data Sink locally, mapping our volume into the Tool Data Sink
# container.

printf -- "\n\nNow we will automatically start the local Tool Data Sink to pull tool data into our local volume.\n\n"

set -x
podman run --name pbench-agent-tool-data-sink --network host --volume ${pbench_run}:/var/lib/pbench-agent:Z --ulimit nofile=65536:65536 --rm -d -e REDIS_HOST=${REDIS_HOST} -e REDIS_PORT=${REDIS_PORT} -e PARAM_KEY=tds-default -e _PBENCH_TOOL_DATA_SINK_LOG_LEVEL=debug quay.io/pbench/pbench-agent-tool-data-sink-${DISTRO}:${TAG}
set +x

printf -- "\n\nOptional: Now let's look at the 'podman logs' output from these containers;\n\t You will notice if we did not start a Redis server yet,\n\tthey'll just be waiting for it to show up.\n\n"

wait_keypress 120


printf -- "\n\nPlease start the Redis server on ${REDIS_HOST}:${REDIS_PORT} if not currently up\n\t$ podman run --name demo-tm-redis -p ${REDIS_PORT}:6379 --rm -d redis\n\n\tNote TDS and TMs notice Redis server,\n\tbut now wait for their 'PARAM_KEY' to show up.\n\n"

wait_keypress 120

export date="2021-1-1T12:00:00"

source /etc/profile.d/pbench-agent.sh
source /opt/pbench-agent/base

group="default"

export script="demo"
export config="my-demo-config-000"
export benchmark_run_dir="${pbench_run}/${script}_${config}_${date_suffix}"
mkdir ${benchmark_run_dir}

printf -- "\n\nTypically pbench-tool-meister-start is expecting a '\${benchmark_run_dir}' to store data\nwhich is usually created by a pbench-user-benchmark and the like.\nWe mimic the same behavior with:\n\n\tbenchmark_run_dir='${benchmark_run_dir}'\n\n"

wait_keypress 120

printf -- "\n\nNow we will begin with data collection, but before doing so, feel free to run this on any tool-meister hosts:\n\n\t$ podman run docker.io/alexeiled/stress-ng --cpu 4 --io 2 --timeout 300s --metrics-brief\n\nThis will serve as a sample workload to demonstrate meaningful data collection.\nIt runs for 300s by default, but feel free to alter that value (or ctrl-c for early graceful exit).\n\n"

wait_keypress 120

# Start the Tool Meisters, collecting system information, and start any persistent tools.
set -x
_PBENCH_TOOL_MEISTER_START_LOG_LEVEL=debug pbench-tool-meister-start --orchestrate=existing --redis-server=${REDIS_HOST}:${REDIS_PORT} --tool-data-sink=${CONTROLLER} --sysinfo=default ${group} 2>&1 | less -S
set +x

printf -- "\n\nThe operation of pbench-tool-meister-start created the keys containing the operational data for the Tool Data Sink and the Tool Meisters, then issued the first 'sysinfo' collection, as requested, and sent the 'init' persistent tools command.\n\nAt this point any registered persistent tools are up and running. Next is the handling of transient tool start/stop.\n\n"
wait_keypress 120

# Option to start grafana, where it is listening on port 3000.
printf -- "\n\nYou can also now run a live metrics visualizer for the Prometheus & PCP data\n\n\t$ podman run --network host -d --rm --name pbench-viz quay.io/pbench/live-metric-visualizer\n\n"

printf -- "\n\nIf done, open a browser to watch live metrics at: %s\n\n" "http://$(hostname -f):3000/"
wait_keypress 120


# TBD start/stop/send tools

printf -- "\n\nNow we will start and stop two iterations of transient tool data collection.\n"

sample="sample42"
iterations="0-iter-zero 1-iter-one"

> ${benchmark_run_dir}/.iterations

for iteration in ${iterations}; do
    echo "${iteration}" >> ${benchmark_run_dir}/.iterations
    benchmark_results_dir="${benchmark_run_dir}/${iteration}/${sample}"
    mkdir -p ${benchmark_results_dir}

    printf -- "\n\nStarting iteration '${iteration}'; when we continue the transient tools will be started.\n\n"
    wait_keypress 120

    pbench-start-tools --group="${group}" --dir="${benchmark_results_dir}"

    printf -- "\n\nTransient tools have started for iteration '${iteration}'; when we continue they'll be stopped.\n\n"
    wait_keypress 120

    pbench-stop-tools --group="${group}" --dir="${benchmark_results_dir}"

    printf -- "\n\nTools have stopped for iteration '${iteration}'; each Tool Meister still has the data held locally.\n\n"
    wait_keypress 120
done

printf -- "\n\nWe have completed our two iterations, and next we'll loop through those iterations requesting the tool data be sent back to the Tool Data Sink.\n\n"
wait_keypress 120

for iteration in ${iterations}; do
    benchmark_results_dir="${benchmark_run_dir}/${iteration}/${sample}"
    pbench-send-tools --group="${group}" --dir="${benchmark_results_dir}"
done


# Stop the Tool Meisters, collecting system information, and stopping any persistent tools.

printf -- "\n\nWe have gathered the transient data from our two iterations, and next we'll stop the Tool Meisters; this involves ending any persistent tools, and gathering the final 'sysinfo' collection requested.\n\n"
wait_keypress 120

set -x
_PBENCH_TOOL_MEISTER_STOP_LOG_LEVEL=debug pbench-tool-meister-stop --sysinfo=default ${group}
set +x


printf -- "\n\nAt this point the Tool Data Sink has stopped, along with the Tool Meisters. The Redis server is still running, since the pbench-agent CLI commands did not start it.  Next we dump the final directory hierarchy of collected data to complete the test.\n\n"
wait_keypress 120

# Dump our local environment
find ${pbench_run} -ls | less -S

wait_keypress 120

read -p "Would you like the live-metric-visualizer to be terminated if started locally? (y/n): " term_vis
if [ $term_vis == "y" ]
then
    printf -- "Running: podman kill pbench-viz\n"
    podman kill pbench-viz
fi

read -p "\nWould you like the redis container to be terminated if started locally? (y/n): " term_redis
if [ $term_redis == "y" ]
then
    printf -- "Running: podman kill demo-tm-redis\n"
    podman kill demo-tm-redis
fi

printf -- "\nCongratulations, you've completed the full benchmarking process!\n"