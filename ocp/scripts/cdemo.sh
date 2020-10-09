#!/bin/bash

echo -ne "Enter your quay.io username: "
read QUAY_USER
echo -ne "Enter your quay.io password: "
read -s QUAY_PASSWORD
echo -ne "\nEnter your Git Token: "
read -s GIT_AUTH_TOKEN

echo ""
mkdir -p /var/tmp/code-to-prod-demo/
echo "Deploy Argo CD"
oc create namespace argocd
oc apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v1.6.1/manifests/install.yaml
echo "Create Ingress for Argo CD"
oc -n argocd create route passthrough argocd --service=argocd-server --port=https --insecure-policy=Redirect
ARGOCD_PASSWORD=$(oc -n argocd get pods -l app.kubernetes.io/name=argocd-server -o name | awk -F "/" '{print $2}')
oc -n argocd patch configmap argocd-cm -p '{"data":{"resource.customizations":"extensions/Ingress:\n  health.lua: |\n    hs = {}\n    hs.status = \"Healthy\"\n    return hs\n"}}'
echo "Deploy Tekton Pipelines and Events"
cat <<EOF | oc -n openshift-operators create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator-rh
spec:
  channel: ocp-4.4
  installPlanApproval: Automatic
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
# TODO: wait for subscription instead of sleeping
sleep 120
mkdir -p /var/tmp/code-to-prod-demo
git clone https://github.com/rgupta1234/reverse-words.git /var/tmp/code-to-prod-demo/reverse-words
git clone https://github.com/rgupta1234/reverse-words-cicd.git /var/tmp/code-to-prod-demo/reverse-words-cicd
cd /var/tmp/code-to-prod-demo/reverse-words-cicd
git checkout ci
sleep 10
echo "Create Tekton resources for the demo"
oc create namespace reversewords-ci
gsed -i "s/<username>/$QUAY_USER/" quay-credentials.yaml
gsed -i "s/<password>/$QUAY_PASSWORD/" quay-credentials.yaml
oc -n reversewords-ci create secret generic image-updater-secret --from-literal=token=${GIT_AUTH_TOKEN}
oc -n reversewords-ci create -f quay-credentials.yaml
oc -n reversewords-ci create -f pipeline-sa.yaml
oc -n reversewords-ci create -f lint-task.yaml
oc -n reversewords-ci create -f test-task.yaml
oc -n reversewords-ci create -f build-task.yaml
oc -n reversewords-ci create -f image-updater-task.yaml
gsed -i "s|<reversewords_git_repo>|https://github.com/rgupta1234/reverse-words|" build-pipeline.yaml
gsed -i "s|<reversewords_quay_repo>|quay.io/rgupta/tekton-reversewords|" build-pipeline.yaml
gsed -i "s|<golang_package>|github.com/rgupta1234/reverse-words|" build-pipeline.yaml
gsed -i "s|<imageBuilder_sourcerepo>|rgupta1234/reverse-words-cicd|" build-pipeline.yaml
oc -n reversewords-ci create -f build-pipeline.yaml
oc -n reversewords-ci create -f webhook-roles.yaml
oc -n reversewords-ci create -f github-triggerbinding.yaml
WEBHOOK_SECRET="v3r1s3cur3"
oc -n reversewords-ci create secret generic webhook-secret --from-literal=secret=${WEBHOOK_SECRET}
gsed -i "s/<git-triggerbinding>/github-triggerbinding/" webhook.yaml
gsed -i "/ref: github-triggerbinding/d" webhook.yaml
gsed -i "s/- name: pipeline-binding/- name: github-triggerbinding/" webhook.yaml
oc -n reversewords-ci create -f webhook.yaml
oc -n reversewords-ci create -f curl-task.yaml
oc -n reversewords-ci create -f get-stage-release-task.yaml
gsed -i "s|<reversewords_cicd_git_repo>|https://github.com/rgupta1234/reverse-words-cicd|" promote-to-prod-pipeline.yaml
gsed -i "s|<reversewords_quay_repo>|quay.io/rgupta1234/tekton-reversewords|" promote-to-prod-pipeline.yaml
gsed -i "s|<imageBuilder_sourcerepo>|rgupta1234/reverse-words-cicd|" promote-to-prod-pipeline.yaml
gsed -i "s|<stage_deployment_file_path>|./deployment.yaml|" promote-to-prod-pipeline.yaml
oc -n reversewords-ci create -f promote-to-prod-pipeline.yaml
oc -n reversewords-ci create route edge reversewords-webhook --service=el-reversewords-webhook --port=8080 --insecure-policy=Redirect
sleep 15
ARGOCD_ROUTE=$(oc -n argocd get route argocd -o jsonpath='{.spec.host}')
argocd login $ARGOCD_ROUTE --insecure --username admin --password $ARGOCD_PASSWORD
argocd account update-password --account admin --current-password $ARGOCD_PASSWORD --new-password 'r3dh4t1!'
CONSOLE_ROUTE=$(oc -n openshift-console get route console -o jsonpath='{.spec.host}')
echo "Argo CD Console: $ARGOCD_ROUTE"
echo "OCP Console: $CONSOLE_ROUTE"
