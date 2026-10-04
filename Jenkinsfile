// Build, test and deploy the trading platform to the EKS cluster.
//
// Runs on the Jenkins machine itself (the EC2 "test" box), which already has
// Docker, kubectl and an AWS role that can push to ECR and manage the
// cluster. No keys are stored in Jenkins.
//
// One-time cluster preparation is scripts/bootstrap.sh, not this pipeline.
pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    timeout(time: 45, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '15'))
  }

  // GitHub calls http://<jenkins>:8080/github-webhook/ on every push, which
  // starts a build within seconds. The slow poll is only a safety net for a
  // missed call, for example while the box was stopped.
  triggers {
    githubPush()
    pollSCM('H */2 * * *')
  }

  environment {
    AWS_REGION = 'ap-south-1'
  }

  stages {
    // Tests run in throwaway containers, so the box needs no Java or Node.
    stage('Test trade API') {
      steps {
        sh '''
          mkdir -p "$HOME/.m2"
          docker run --rm -u "$(id -u):$(id -g)" \
            -v "$PWD/sprint8":/app -w /app \
            -v "$HOME/.m2":/var/maven/.m2 -e MAVEN_CONFIG=/var/maven/.m2 \
            maven:3.9.9-eclipse-temurin-21 mvn -B -q -Duser.home=/var/maven test
        '''
      }
    }

    stage('Test auth service') {
      steps {
        sh '''
          docker run --rm -u "$(id -u):$(id -g)" \
            -e HOME=/tmp -e npm_config_cache=/tmp/.npm \
            -v "$PWD/sprint8-auth-service":/app -w /app \
            node:20-alpine sh -c "npm ci --no-audit --no-fund && npm test"
        '''
      }
    }

    stage('Build and push images') {
      // Images are tagged with the commit they were built from.
      steps { sh './scripts/build-push.sh "$(git rev-parse --short=12 HEAD)"' }
    }

    stage('Deploy to EKS') {
      steps { sh './scripts/deploy.sh "$(git rev-parse --short=12 HEAD)"' }
    }

    stage('Smoke test') {
      steps { sh './scripts/smoke-test.sh' }
    }
  }

  post {
    success { echo 'Deployed and smoke-tested.' }
    failure { echo 'Failed. The cluster keeps running the last version that rolled out.' }
    // Test containers and build leftovers, whatever the outcome.
    always  { sh 'docker image prune -f >/dev/null || true' }
  }
}
