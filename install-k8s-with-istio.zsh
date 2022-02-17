#!/bin/zsh
# deploy k3d cluster with extra memory (8G) for Istio install
k3d cluster create local-cluster --servers 1 --agents 1 --api-port 6443 --k3s-arg "--disable=traefik@server:0" --port 8080:80@loadbalancer --port 8443:443@loadbalancer --agents-memory=8G
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=$ISTIO_VERSION sh -
cd "$PWD/istio-$ISTIO_VERSION/"
export PATH=$PWD/bin:$PATH

#https://istio.io/latest/docs/setup/install/operator/
#install istio operator:
#    NOTE: above command runs the operator by creating the following resources in the istio-operator namespace:
#    - The operator custom resource definition
#    - The operator controller deployment
#    - A service to access operator metrics
#    - Necessary Istio operator RBAC rules
istioctl operator init

#https://istio.io/latest/docs/setup/install/operator/
# deploy Istio default configuration profile using the operator, run the following command:
#     the default profile…
#     Ingress Gateway is enabled
#     Istiod is enabled
kubectl apply -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: istio-system
  name: default-istiocontrolplane
spec:
  profile: default
EOF
echo "Waiting for Istio to be ready..."
sleep 15

# https://istio.io/latest/docs/setup/getting-started/ 
kubectl label namespace default istio-injection=enabled

# deploy app and Istio configuration
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-world
  labels:
    app: hello-world
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hello-world
  template:
    metadata:
      labels:
        app: hello-world
    spec:
      containers:
        - image: $IMAGE
          name: hello-world
          ports:
            - containerPort: 80
---
kind: Service
apiVersion: v1
metadata:
  name: hello-world
  labels:
    app: hello-world
spec:
  selector:
    app: hello-world
  ports:
    - port: 80
      name: http
      targetPort: 80
---
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: local-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - '*'
    - port:
        number: 443
        name: https
        protocol: HTTPS
      tls:
        mode: SIMPLE
        credentialName: helloworld-localhost-credential
      hosts:
        - '*'
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: helloworld
spec:
  hosts:
    - '*'
  gateways:
    - local-gateway
  http:
    - route:
      - destination:
          host: hello-world.default.svc.cluster.local
          port:
            number: 80
EOF

# certificate creaton for SSL/TLS termination
#create the root certificate called localhost.crt and the private key used for signing the certificate:
openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 -subj "/O=$DOMAIN_NAME Inc./CN=$DOMAIN_NAME" -keyout $DOMAIN_NAME.key -out $DOMAIN_NAME.crt 
  
#create the certificate signing request and the corresponding key
openssl req -out helloworld.$DOMAIN_NAME.csr -newkey rsa:2048 -nodes -keyout helloworld.$DOMAIN_NAME.key -subj "/CN=helloworld.$DOMAIN_NAME/O=hello world from $DOMAIN_NAME"

#using the certificate authority and it's key as well as the certificate signing requests, we can create our own self-signed certificate
openssl x509 -req -days 365 -CA $DOMAIN_NAME.crt -CAkey $DOMAIN_NAME.key -set_serial 0 -in helloworld.$DOMAIN_NAME.csr -out helloworld.$DOMAIN_NAME.crt

#Now that we have the certificate and the correspondig key we can create a Kubernetes secret to store them in our cluster.
#We will create the secret in the istio-system namespace and reference it from the Gateway resource:
kubectl create -n istio-system secret tls helloworld-localhost-credential --key=helloworld.localhost.key --cert=helloworld.localhost.crt

echo "Application via Istio Ingress (https): https://helloworld.localhost:8443"
echo "Application via Istio Ingress (http):  http://helloworld.localhost:8080"
#launch/verify application via Istio
echo "Launching application..."
sleep 5
open https://helloworld.localhost:8443