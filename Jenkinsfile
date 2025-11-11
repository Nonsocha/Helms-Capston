pipeline { 
    agent any

    environment {
        IMAGE = "sirwills/myapp"
        CHART = "myapp-chart"
        KUBECONFIG_PATH = "/var/lib/jenkins/.kube/config" // Jenkins-owned kubeconfig
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Build Docker') {
            steps {
                script {
                    sh "docker build -t ${IMAGE}:${GIT_COMMIT.substring(0,7)} ."
                }
            }
        }

        stage('Push Docker') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'dockerhub-creds', usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
                    sh """
                        echo \$DOCKER_PASS | docker login -u \$DOCKER_USER --password-stdin
                        docker push ${IMAGE}:${GIT_COMMIT.substring(0,7)}
                    """
                }
            }
        }

        stage('Deploy with Helm') {
            steps {
                script {
                    sh """
                        export KUBECONFIG=${KUBECONFIG_PATH}
                        helm upgrade --install myapp ./myapp \\
                            --namespace demo --create-namespace \\
                            --set image.repository=${IMAGE},image.tag=${GIT_COMMIT.substring(0,7)} \\
                            --wait --timeout 5m --atomic
                    """
                }
            }
        }
    }

    post {
        success {
            echo "Pipeline succeeded"
        }
        failure {
            echo "Pipeline failed"
        }
    }
}

