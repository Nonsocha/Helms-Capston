pipeline {
    agent any

    environment {
        IMAGE = "sirwills/myapp"
        CHART = "myapp-chart"
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
                    // Use double quotes for variable substitution
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
                withCredentials([file(credentialsId: 'kubeconfig-file', variable: 'KUBECONFIG')]) {
                    sh """
                        export KUBECONFIG=\$KUBECONFIG
                        helm upgrade --install myapp ./myapp-chart \\
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
