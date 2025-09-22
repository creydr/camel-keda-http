# camel-keda

## Kafka Source

Source to read from a Kafka given topic and sending it as a CloudEvent to a given sink.

1. Create a Cluster with a local registry and Kafka (e.g. via [./hack/create-kind-cluster.sh](./hack/create-kind-cluster.sh))
2. Deploy a Sink service. E.g. event-display:
    ```
    cat <<-EOF | kubectl apply -f  -
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
3. Build and deploy the kafka-source to the local registry (localhost:5001):
   ```
   mvn package
   ```
4. Apply manifests (and optionally adjust before):
   ```
   kubectl apply -f kafka-source/target/kubernetes/kubernetes.yml
   ```
5. Test if messages get sent to sink: 
   1. Produce some Kafka messages in the topic
      ```
      kubectl -n kafka run kafka-producer --rm -ti --image=quay.io/strimzi/kafka:0.47.0-kafka-4.0.0 --rm=true --restart=Never -- bin/kafka-console-producer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic
      ```
   2. check the event-display logs
      ```
      kubectl logs -l app=event-display
      ```
