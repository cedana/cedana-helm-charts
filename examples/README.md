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

Great! Now its time to checkpoint the container. Lets set necessary environment variables before we proceed. The following variables should work on most default containerd clusters.

```bash
kubectl port-forward service/ -n cedanacontroller-system 1324:1324
```

```bash
export CHECKPOINT_CONTAINER=redis \
export CHECKPOINT_SANDBOX=redis-6b5bcbb6b6-tdb4p \
export RESTORE_CONTAINER=redis-restore \
export RESTORE_SANDBOX=redis-restore-c6c794b64-h7ccs \
export NAMESPACE=cedana-examples \
export CONTROLLER_URL=localhost \
export ROOT=/run/containerd/runc/k8s.io \
export CHECKPOINT_PATH=/tmp/ckpt-redis
```
Let's try to list all the pods in `cedana-examples` namespace

```bash
curl -X GET -H 'Content-Type: application/json' -d '{
  "root": "'$ROOT'"
}' $CONTROLLER_URL:1324/list/cedana-examples
```
Runc container checkpoint

```bash
curl -X POST -H "Content-Type: application/json" -d '{
  "checkpoint_data": {
    "container_name": "'$CHECKPOINT_CONTAINER'",
    "sandbox_name": "'$CHECKPOINT_SANDBOX'",
    "namespace": "'$NAMESPACE'",
    "checkpoint_path": "'$CHECKPOINT_PATH'",
    "root": "'$ROOT'"
  }
}' http://$CONTROLLER_URL:1324/checkpoint
```

Once this completes, we need a new pod to restore the redis data into. This pod must be in inactive state to accomplish a successful restore and to do this we will put the pod in `sleep infinity` state.

```bash
k apply -f redis-restore-example.yaml
```

Now restore the container using the following commands

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
Finally connect to redis-cli once again to check if the new restored container has the previously set data

```bash
HGETALL user:001
HGETALL user:002
```

## Jupyter Notebook checkpoint restore
Now lets try checkpointing a jupyter notebook using CRIO runtime. This example includes us training against an MNIST dataset (basically have a model classify numbers based on images). Let's start with creating the empty notebook to be checkpointed.

```bash
kubectl apply -f jupyter-example.yaml -f -n cedana-examples
```
Now portforward the jupyter-notebook pod to your local.
```bash
kubectl port-forward pod/jupyter-notebook -n cedana-examples 8888:8888
```
pip install to install necessary modules for training
```bash
pip install torch torchvision numpy
```
Time to run the actual code in the checkpoint containr notebook:
```python
import torch
import torch.nn as nn
import torch.optim as optim
from torchvision import datasets, transforms
from torch.utils.data import DataLoader
import numpy

# Define a very simple neural network with one linear layer
class SimpleNN(nn.Module):
    def __init__(self):
        super(SimpleNN, self).__init__()
        self.fc = nn.Linear(28 * 28, 10)  # Input: 28*28 (flattened image), Output: 10 (class scores)

    def forward(self, x):
        x = x.view(-1, 28 * 28)  # Flatten the input
        x = self.fc(x)
        return x

# Setup device
device = torch.device('cpu')  # Using CPU

# Create the model and move it to the device
model = SimpleNN().to(device)

# Loss function and optimizer
criterion = nn.CrossEntropyLoss()
optimizer = optim.SGD(model.parameters(), lr=0.01)

# Data transformations
transform = transforms.Compose([
    transforms.ToTensor(),
    transforms.Normalize((0.5,), (0.5,))
])

# Load MNIST dataset
train_dataset = datasets.MNIST(root='./data', train=True, transform=transform, download=True)
train_loader = DataLoader(dataset=train_dataset, batch_size=64, shuffle=True)

# Training loop (1 epoch)
for epoch in range(1):  # Single epoch
    model.train()
    for images, labels in train_loader:
        images, labels = images.to(device), labels.to(device)

        # Forward pass
        outputs = model(images)
        loss = criterion(outputs, labels)

        # Backward pass and optimization
        optimizer.zero_grad()
        loss.backward()
        optimizer.step()

    print(f'Epoch {epoch+1}: Loss: {loss.item()}')

print('Training complete')

# Evaluation on test dataset
test_dataset = datasets.MNIST(root='./data', train=False, transform=transform, download=True)
test_loader = DataLoader(dataset=test_dataset, batch_size=1000, shuffle=False)

model.eval()
correct = 0
total = 0

with torch.no_grad():
    for images, labels in test_loader:
        images, labels = images.to(device), labels.to(device)
        outputs = model(images)
        _, predicted = torch.max(outputs.data, 1)
        total += labels.size(0)
        correct += (predicted == labels).sum().item()
accuracy = 100 * correct / total
print(f'Accuracy: {accuracy}%')
```

Assuming the cedana service is still port-forwarded at 1324, lets run CRIO rootfs checkpoint on the container. Note that we must provide credentials to push rootfs as an image to the specified registry of your choice.

```bash
# Enter your container registry username and password and the name of the image you want to push
export username=""
export password=""
export new_image_ref=""
```
```bash
	registry_auth=$(echo -n $username:$password | base64 -w 0)
	jupyter_sandbox_name=$(kubectl get po -n cedana-examples  --no-headers=true | grep jupyter-notebook | cut -d " " -f 1)
	response=$(curl -X POST -H "Content-Type: application/json" -d '{
	"container_name": "jupyter-container",
	"root": "/run/runc",
	"sandbox_name": "'$jupyter_sandbox_name'",
	"namespace": "cedana-examples",
	"registry_auth_data": {
  	"pull_auth_token": "'$registry_auth'",
  	"push_auth_token": "'$registry_auth'"
	},
	"image_ref": "docker.io/jupyter/base-notebook:latest",
	"new_image_ref": "'$new_image_ref'"
	}' http://localhost:1324/checkpoint/rootfs/crio)
	echo "crio_rootfs_checkpoint_response: $response"
```
