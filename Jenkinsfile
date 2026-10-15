pipeline {
    agent any

    environment {
        IMAGE_NAME = "imbah300/cw2-server"
        IMAGE_TAG = "1.0"
        PROD_SERVER = "ubuntu@ec2-44-223-60-161.compute-1.amazonaws.com"
        PROD_PLAYBOOK = "k8s.yml"
        DOCKER_CREDS = credentials('docker')
    }

    stages {

        stage('Checkout Source Code') {
            steps {
                git branch: 'main',
                    url: 'https://github.com/Mbahvictor16/devops_cw2.git'
            }
        }

        stage('Build Docker Image') {
            steps {
                sh """
                    docker build -t ${IMAGE_NAME}:${IMAGE_TAG} .
                """
            }
        }

        stage('Test Container Launch') {
            steps {
                sh """
                    docker run -d --name test-container -p 8081:8081 ${IMAGE_NAME}:${IMAGE_TAG}
                    sleep 10
                    docker ps | grep test-container
                    docker exec test-container echo "Container started successfully"
                    docker stop test-container
                    docker rm test-container
                """
            }
        }

        stage('Login to DockerHub') {
            steps {
               
                sh """
                    echo $DOCKER_CREDS_PSW | docker login -u "mbahvictor" --password-stdin
                """
            }
        }

        stage('Push to DockerHub') {
            steps {
               
                sh """
                    docker push ${IMAGE_NAME}:${IMAGE_TAG}
                """
            }
        }

        stage('Deploy to Production via Ansible') {
            steps {
                sshagent(['prod-ssh-key']) {
                    sh """
                        ssh -o StrictHostKeyChecking=no ${PROD_SERVER} \
                        'ansible-playbook ${PROD_PLAYBOOK}'
                    """
                }
            }
        }
    }

    post {
        success {
            echo 'Build, test, push, and deployment completed successfully.'
        }

        failure {
            echo 'Pipeline failed. Check the logs above for details.'
        }
    }
}
