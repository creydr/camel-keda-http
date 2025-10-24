# camel-keda

This project demonstrates two separate Camel applications for interacting with Kafka.

*   **kafka-source**: Reads messages from a Kafka topic and sends them as CloudEvents to a user application.
*   **kafka-sink**: Receives HTTP POST requests and publishes their bodies to a Kafka topic.

## Setup

1.  Create a Kubernetes cluster with a local registry and Kafka by running the setup script:
    ```bash
    ./hack/create-kind-cluster.sh
    ```
2.  The `kafka-source` needs a "user application" to send events to. Deploy a simple event-display application for this purpose:
    ```bash
    cat <<-EOF | kubectl apply -f -
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: event-display
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: event-display
      template:
        metadata:
          labels:
            app: event-display
        spec:
          containers:
            - name: event-display
              image: gcr.io/knative-releases/knative.dev/eventing/cmd/event_display
              ports:
              - containerPort: 8080
    ---
    apiVersion: v1
    kind: Service
    metadata:
      name: event-display
    spec:
      selector:
        app: event-display
      ports:
        - name: http
          port: 80
          targetPort: 8080
    EOF
    ```
3.  Build the container images for both applications and push them to the local registry:
    ```bash
    mvn package
    ```
4.  Deploy both Camel applications to the cluster:
    ```bash
    kubectl apply -f kafka-source/target/kubernetes/kubernetes.yml
    kubectl apply -f kafka-sink/target/kubernetes/kubernetes.yml
    ```

## Testing

### Flow 1: Kafka Source to User App

Test sending a message from a Kafka topic to the `event-display` application.

1.  In a separate terminal, watch the logs of the `event-display` service:
    ```bash
    kubectl logs -l app=event-display -f
    ```
2.  In your primary terminal, produce a message to the `my-topic` Kafka topic. Type your message and press Enter, then `Ctrl+D` to exit.
    ```bash
    kubectl -n kafka run kafka-producer --rm -ti --image=quay.io/strimzi/kafka:0.47.0-kafka-4.0.0 --restart=Never -- bin/kafka-console-producer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic
    ```
3.  Observe the CloudEvent output in the `event-display` logs.

### Flow 2: User App (Simulated) to Kafka Sink

Test sending a message from a simulated user application to the `kafka-sink`.

1.  In a separate terminal, start a Kafka consumer to listen for messages on `my-sink-topic`:
    ```bash
    kubectl -n kafka run kafka-consumer --rm -ti --image=quay.io/strimzi/kafka:0.47.0-kafka-4.0.0 --restart=Never -- bin/kafka-console-consumer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-sink-topic
    ```
2.  In your primary terminal, simulate a user application by sending an HTTP POST request to the `kafka-sink` service using a temporary `curl` pod:
    ```bash
    kubectl run curl --image=curlimages/curl -i --rm --restart=Never -- curl -X POST -H "Content-Type: text/plain" --data "Hello from user app" http://kafka-sink/
    ```
3.  You should see "Hello from user app" appear in the Kafka consumer's terminal.
