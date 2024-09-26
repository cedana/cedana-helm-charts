# Cedana examples

## Redis checkpoint restore

Let first set up a sample redis database on k8. Create a namespace called `cedana-examples` and install redis-example.yaml.

```bash
kubectl create namespace cedana-examples
kubectl apply -f redis-example.yaml
```
Now let's port-forward the service on 127.0.0.1 and connect to the database 

```bash
kubectl port-forward service/redis -n cedana-examples 6379:6379
redis-cli -h 127.0.0.1
```

Lets store some data on redis to test checkpoint restore

```bash
HSET 'user:001' first_name 'John' last_name 'doe' dob '12-JUN-1970'
HSET 'user:002' first_name 'David' last_name 'Bloom' dob '03-MAR-1981'
```

Great! Now its time to checkpoint the container. Lets set necessary environment variables before we proceed.

```bash
export CHECKPOINT_CONTAINER=redis \
export CHECKPOINT_SANDBOX=default \
export RESTORE_CONTAINER=redis-1 \
export RESTORE_SANDBOX=default \
export NAMESPACE=k8s.io \
export CONTROLLER_URL=localhost \
export ROOT=root 
```

```bash
curl -X POST -H "Content-Type: application/json" -d '{
  "checkpoint_data": {
    "container_name": "'$CHECKPOINT_CONTAINER'",
    "sandbox_name": "'$CHECKPOINT_SANDBOX'",
    "namespace": "'$NAMESPACE'",
    "checkpoint_path": "'$CHECKPOINT_PATH'",
    "root": "'$ROOT'"
  },
  "leave_running": false
}' http://$CONTROLLER_URL:1324/checkpoint
```

Once this completes, restore the container using the following commands

```bash
curl -X POST -H "Content-Type: application/json" -d '{
  "checkpoint_data": {
    "container_name": "'$RESTORE_CONTAINER'",
    "sandbox_name": "'$RESTORE_SANDBOX'",
    "namespace": "'$NAMESPACE'",
    "checkpoint_path": "'$CHECKPOINT_PATH'",
    "root": "'$ROOT'"
  }
}' http://$CONTROLLER_URL:1324/restore
```

Now connect to redis-cli once again to check if the new restored container has the previously set data

```bash
HGETALL user:001
HGETALL user:002
```
