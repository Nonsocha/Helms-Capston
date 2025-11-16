# Helm + Jenkins CI/CD Project Guide


## Table of contents

1. Introduction
2. Prerequisites
3. Environment setup

   * Jenkins server
   * Kubernetes (minikube / remote cluster)
   * Helm
   * Docker / registry
4. Create a sample Helm chart (hands-on)
5. Helm templating basics (examples)
6. Deploy the sample app with Helm
7. Integrating Helm with Jenkins

   * Jenkinsfile (full example)
   * Credentials and Jenkins job setup
   * Webhook + ngrok for local Jenkins
8. Test, upgrade and rollback
9. Security & best practices
10. Checklist & deliverables
11. Appendix: full file examples

---

## 1. Introduction

This document walks you through building a simple CI/CD pipeline that uses **Jenkins** to build a Docker image and **Helm** to deploy that image to **Kubernetes**. The guide is beginner-friendly and contains all commands, sample files, and steps needed to go from an empty VM to a working pipeline.

---

## 2. Prerequisites

On the machine(s) you will use (local VM, cloud VM, or remote server) ensure you have:

* An OS with sudo (Ubuntu 20.04+ recommended)
* `curl`, `wget`, `git` installed
* Docker installed and running
* A Kubernetes cluster (minikube for local testing or a cloud cluster)
* Helm 3 installed
* A Docker registry account (Docker Hub, ECR, GHCR etc.)
* A GitHub repository to store your app, Helm chart and `Jenkinsfile`
* A Jenkins server (will be installed below) reachable from GitHub (public or via ngrok)

---

## 3. Environment setup

### 3.1 Install Docker

Ubuntu example:

```bash
sudo apt update
sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io
sudo usermod -aG docker $USER
# Log out & in or `newgrp docker`
```

Verify:

```bash
docker version
```

### 3.2 Install kubectl (if needed)

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

### 3.3 Install Minikube (local testing) or use your cluster

Minikube (linux):

```bash
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
minikube start --driver=docker
```

Check cluster:

```bash
kubectl get nodes
```

### 3.4 Install Helm

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### 3.5 Install Jenkins (Ubuntu example)

```bash
# Java
sudo apt update
sudo apt install -y openjdk-11-jre
# Add Jenkins repo & key
wget -q -O - https://pkg.jenkins.io/debian-stable/jenkins.io.key | sudo tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/ | sudo tee /etc/apt/sources.list.d/jenkins.list
sudo apt update
sudo apt install -y jenkins
sudo systemctl enable --now jenkins
# Get initial admin password
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Open Jenkins at `http://<server-ip>:8080` and complete the setup wizard. Install suggested plugins and create at least one admin user.

### 3.6 Jenkins machine tools: helm, kubectl, docker

Option 1: Install `helm` and `kubectl` on Jenkins host.
Option 2: Use Kubernetes plugin to run pipeline steps inside a pod with those tools installed.

For a simple setup, install `helm` and `kubectl` on the Jenkins server (repeat the commands for Helm and kubectl above).

---

## 4. Create a sample Helm chart (hands‑on)

### 4.1 Scaffold a chart

On your dev machine or inside repo:

```bash
helm create myapp-chart
cd myapp-chart
```

This scaffold includes `Chart.yaml`, `values.yaml`, and `templates/`.

### 4.2 Edit `values.yaml` (example)

```yaml
replicaCount: 1

image:
  repository: nginx
  tag: "1.25"
  pullPolicy: IfNotPresent

service:
  type: NodePort
  port: 80
  nodePort: 30080

resources: {}

# Add env and other settings as needed
```

### 4.3 Key template parts to check

`templates/deployment.yaml` should use `{{ .Values.image.repository }}:{{ .Values.image.tag }}` and `{{ .Values.replicaCount }}`. `templates/service.yaml` should reference `{{ .Values.service.type }}` and optionally `.Values.service.nodePort`.

Run `helm lint` to check for issues:

```bash
helm lint .
```

Render templates locally to inspect final YAML:

```bash
helm template myapp . --values values.yaml
```

---

## 5. Helm templating basics (examples)

* **Values**: `{{ .Values.path.to.value }}`
* **Release & Chart**: `{{ .Release.Name }}`, `{{ .Chart.Name }}`
* **Helpers**: create `templates/_helpers.tpl` with reusable snippets
* **Conditionals**:

  ```gotemplate
  {{- if .Values.service.nodePort }}
  nodePort: {{ .Values.service.nodePort }}
  {{- end }}
  ```
* **YAML helpers**: `toYaml` to inject structured YAML.

Example `_helpers.tpl`:

```gotemplate
{{- define "myapp.name" -}}
{{- default .Chart.Name .Values.nameOverride -}}
{{- end -}}

{{- define "myapp.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "myapp.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
```

---

## 6. Deploy the sample app with Helm

Create namespace `demo` and install the chart:

```bash
helm upgrade --install myapp ./myapp-chart --namespace demo --create-namespace \
  --set image.repository=nginx,image.tag=1.25 --wait --timeout 3m

kubectl get pods -n demo
kubectl get svc -n demo
```

If using Minikube, expose the service:

```bash
minikube service myapp -n demo --url
```

To uninstall:

```bash
helm uninstall myapp -n demo
kubectl delete namespace demo
```

---

## 7. Integrating Helm with Jenkins

This section shows how to use a Jenkins pipeline to build, push a Docker image and deploy with Helm.

### 7.1 Jenkins credentials to add

* `dockerhub-creds` — Username/password (or token)
* `kubeconfig-file` — Add the kubeconfig as a **File** credential
* (Optional) `github-webhook-secret` — Secret token for webhook validation

### 7.2 Sample `Jenkinsfile` (declarative)

```groovy
pipeline {
  agent any

  environment {
    IMAGE = "sirwills/myapp"
    CHART = "myapp-chart"
  }

  stages {
    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Build Docker') {
      steps {
        sh 'docker build -t ${IMAGE}:${GIT_COMMIT.substring(0,7)} .'
      }
    }

    stage('Push Docker') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'dockerhub-creds', usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
          sh '''
            echo $DOCKER_PASS | docker login -u $DOCKER_USER --password-stdin
            docker push ${IMAGE}:${GIT_COMMIT.substring(0,7)}
          '''
        }
      }
    }

    stage('Deploy with Helm') {
      steps {
        withCredentials([file(credentialsId: 'kubeconfig-file', variable: 'KUBECONFIG')]) {
          sh '''
            export KUBECONFIG=$KUBECONFIG
            helm upgrade --install myapp ./myapp-chart \
              --namespace demo --create-namespace \
              --set image.repository=${IMAGE},image.tag=${GIT_COMMIT.substring(0,7)} \
              --wait --timeout 5m --atomic
          '''
        }
      }
    }
  }

  post {
    success { echo "Pipeline success" }
    failure { echo "Pipeline failed" }
  }
}
```

**Notes:**

* Use `${GIT_COMMIT.substring(0,7)}` or `BUILD_NUMBER` for image tags to ensure immutability.
* `withCredentials([file(...)])` writes the kubeconfig to disk and sets `$KUBECONFIG` environment variable in the shell.

### 7.3 Create Jenkins pipeline job and enable webhook trigger

1. In Jenkins: **New Item** → **Pipeline** → choose **Pipeline from SCM** (Git)
2. Provide repo URL, branch, and script path (`Jenkinsfile`).
3. Under **Build Triggers**, enable **GitHub hook trigger for GITScm polling**.


### 7.4 Webhook setup on GitHub & ngrok (for local Jenkins)

If Jenkins is not public, expose it with `ngrok`:

```bash
ngrok http 8080
# copy the https URL like https://abcd1234.ngrok.io
```

On GitHub repo Settings → Webhooks → Add webhook:

* Payload URL: `https://abcd1234.ngrok.io/github-webhook/`
* Content type: `application/json`
* Secret: add a random secret (copy to Jenkins if you will validate)
* Events: **Just the push event**

In Jenkins job, enable GitHub hook trigger and ensure the repository webhook is firing (GitHub shows deliveries).

---

## 8. Test, upgrade and rollback

### 8.1 Trigger a pipeline

* Push a commit to your GitHub repo (e.g., update README or change app code)
* GitHub sends webhook → Jenkins job triggers → build → push → helm upgrade

### 8.2 Monitor deployment

```bash
kubectl get pods -n demo
kubectl logs -l app.kubernetes.io/name=myapp -n demo
helm status myapp -n demo
```

### 9.3 Upgrade example

Change `values.yaml` or update image tag and push. Jenkins will build a new image and deploy.

Manual Helm upgrade example:

```bash
helm upgrade myapp ./myapp-chart --namespace demo --set image.tag=1.26 --wait --atomic
```

### 8.4 Rollback

Check history and rollback:

```bash
helm history myapp -n demo
helm rollback myapp 1 -n demo
```

---

## 9. Security & best practices

* **Credentials management:** use Jenkins credentials (do not hardcode). Use Vault for production.
* **Least privilege:** run containers with non-root where possible; restrict Jenkins user rights.
* **Kubeconfig:** limit cluster privileges of the Jenkins service account. Use RBAC.
* **Secrets:** use Kubernetes Secrets or external secret managers — do not put secrets in `values.yaml` in repo.
* **Image scanning:** integrate vulnerability scanning into the pipeline.

---

## 10. Checklist & deliverables

* [ ] Jenkins installed and reachable
* [ ] Helm installed and chart ready
* [ ] Docker registry creds stored in Jenkins
* [ ] kubeconfig stored in Jenkins
* [ ] Jenkinsfile in repo
* [ ] GitHub webhook configured
* [ ] Successful pipeline run (build → push → helm deploy)
* [ ] Documentation (this README)

Deliverables (from your screenshots):

* Documentation for Helm chart components
* Simplified security measures at each step
* Step-by-step CI/CD demonstration

---

## 11. Appendix: full file examples

### `Chart.yaml`

```yaml
apiVersion: v2
name: myapp-chart
description: A Helm chart for Kubernetes
type: application
version: 0.1.0
appVersion: "1.0"
```

### `values.yaml` (example)

```yaml
replicaCount: 1

image:
  repository: yourdockeruser/myapp
  tag: "latest"
  pullPolicy: IfNotPresent

service:
  type: NodePort
  port: 80
  nodePort: 30080
```

### `templates/_helpers.tpl`

```gotemplate
{{- define "myapp.name" -}}
{{- default .Chart.Name .Values.nameOverride -}}
{{- end -}}

{{- define "myapp.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "myapp.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
```

### `templates/deployment.yaml` (trimmed)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "myapp.fullname" . }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ include "myapp.name" . }}
  template:
    metadata:
      labels:
        app: {{ include "myapp.name" . }}
    spec:
      containers:
        - name: {{ include "myapp.name" . }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports:
            - containerPort: 80
```
