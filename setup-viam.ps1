Function Test-CommandExists

{

 Param ($command)

 $oldPreference = $ErrorActionPreference

 $ErrorActionPreference = ‘stop’

 try {if(Get-Command $command){
     return $true
 }}

 Catch {return $false}

 Finally {$ErrorActionPreference=$oldPreference}

} 

function CreateCluster(){
    $clusters = kind get clusters
    if ($clusters.Length -gt 0)
    {
        kind delete cluster
    }


    kind create cluster --config kind.yaml
    
    #wait for the cluster to be stable
    Start-Sleep -Seconds 5
    kubectl wait --namespace ingress-nginx --for=condition=ready --selector=tier=node -n kube-system pod --timeout=240s
    kubectl wait --namespace ingress-nginx --for=condition=ready --selector=tier=control-plane -n kube-system pod --timeout=240s
    
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
    Start-Sleep -Seconds 5
    kubectl wait --namespace ingress-nginx --for=condition=ready --selector=app.kubernetes.io/component=controller pod --timeout=240s
    $webhook = kubectl get validatingwebhookconfigurations ingress-nginx-admission -o yaml 
    kubectl delete validatingwebhookconfigurations ingress-nginx-admission
}

function ConfigureHostfile(){
    if ($(Test-CommandExists Add-HostEntry) -eq $false){
        Install-Module pshosts
    }

    if ($(Test-CommandExists ConvertFrom-YAML) -eq $false){
        Install-Module powershell-yaml -AcceptLicense
    }
}

function ConfigureChoco(){
    if ($(Test-CommandExists choco) -eq $false){
        Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    }

    #install kubectl, helm, kind
    choco install pwsh kubernetes-cli kubernetes-helm kind k9s --confirm
    RefreshEnv

    #install helm repos
    helm repo add cockroachdb https://charts.cockroachdb.com/
    helm repo add ory https://k8s.ory.sh/helm/charts
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm repo add stable https://charts.helm.sh/stable


}

function ConfigureDapr(){
    if ($(Test-CommandExists dapr) -eq $false){
        powershell -Command "iwr -useb https://raw.githubusercontent.com/dapr/cli/master/install/install.ps1 | iex"
    }
    dapr init -k --enable-ha=true
    #wait for Dapr to finish

    kubectl wait --for=condition=ready --selector=app.kubernetes.io/part-of=dapr pod -n dapr-system --timeout=240s


    #install Redis first
    helm install redis bitnami/redis
    #create the identity namespace
    kubectl create ns identity
    #install the dapr helpers
    kubectl apply -f .\dapr.yaml
    kubectl apply -f .\dapr.yaml
    #copy redis password to identity namespace
    $secret = kubectl get secret redis -o jsonpath="{..redis-password}"
    $secret = [System.Text.Encoding]::Default.GetString([System.Convert]::FromBase64String($secret))
    kubectl create secret generic redis -n identity --from-literal=redis-password=$($secret)
}

function InstallOryStack(){


#install cockroach 
helm install cockroach cockroachdb/cockroachdb -n identity --set ingress.enabled=true --set ingress.hosts[0]=cockroachdb.k8s.local
kubectl wait --for=condition=ready --selector=app.kubernetes.io/component=cockroachdb pod -n identity --timeout=240s
#create the dbs
kubectl run -it --rm cockroach-client --image=cockroachdb/cockroach --restart=Never --command -- ./cockroach sql --insecure --host=cockroach-cockroachdb-public.identity -e "CREATE DATABASE HYDRA;CREATE DATABASE KRATOS;CREATE DATABASE KETO;SHOW DATABASES"

#install hydra
helm pull ory/hydra -d .\Ory\Hydra --version 0.19.3
helm install hydra .\Ory\Hydra\hydra-0.19.3.tgz -f .\Ory\Hydra\values.yaml -n identity --set maester.enabled=false --set ingress.admin.enabled=false
helm install hydra-admin .\Ory\Hydra\hydra-0.19.3.tgz -f .\Ory\Hydra\values.yaml -n identity --set "deployment.annotations.\dapr\.io\/app-id=hydra-admin" --set "deployment.annotations.\dapr\.io\/app-port='4445'" --set ingress.public.enabled=false
kubectl create rolebinding hydra-secrets-reader --role secret-reader --serviceaccount identity:hydra -n identity
kubectl create rolebinding hydra-admin-secrets-reader --role secret-reader --serviceaccount identity:hydra-admin -n identity

#install kratos
helm pull ory/kratos -d .\Ory\Kratos --version 0.19.3
Write-Output "Installing Kratos, this might take time as migrations last almost 8 mins"
helm install kratos .\Ory\Kratos\kratos-0.19.3.tgz -f .\Ory\Kratos\values.yaml -n identity --timeout 10m0s
kubectl create rolebinding kratos-secrets-reader --role secret-reader --serviceaccount identity:kratos -n identity
helm install kratos-admin .\Ory\Kratos\kratos-0.19.3.tgz -f .\Ory\Kratos\values-admin.yaml -n identity 
kubectl create rolebinding kratos-admin-secrets-reader --role secret-reader --serviceaccount identity:kratos-admin -n identity

#install sample UI
helm pull ory/kratos-selfservice-ui-node -d .\Ory\Kratos --version 0.19.3
helm install kratos-ui .\Ory\Kratos\kratos-selfservice-ui-node-0.19.3.tgz -f .\Ory\Kratos\ui-values.yaml -n identity

#install keto
helm pull ory/keto -d .\Ory\Keto --version 0.19.3
helm install keto .\Ory\Keto\keto-0.19.3.tgz -f .\Ory\Keto\values.yaml -n identity
kubectl create rolebinding keto-secrets-reader --role secret-reader --serviceaccount identity:keto -n identity
}

function Configure-RedisInsights(){

    $secret = kubectl get secret redis -o jsonpath="{..redis-password}"
    $secret = [System.Text.Encoding]::Default.GetString([System.Convert]::FromBase64String($secret))
    $uri = "https://redisinsights.k8s.local:8443/add/?name=Vonage IAM Redis&host=redis-master.default&port=6379&password=$($secret)&redirect=true"
     
    start $uri  
    
}

function SafeAdd-HostEntry{
    
    Param ($hostString)


    $oldPreference = $ErrorActionPreference

 $ErrorActionPreference = ‘stop’

 try {if(Get-HostEntry $hostString){
     return $true
 }}

 Catch {
     Add-HostEntry $hostString 127.0.0.1
 }

 Finally {$ErrorActionPreference=$oldPreference}
    

}

function OpenPages(){

    SafeAdd-HostEntry dapr.k8s.local
    SafeAdd-HostEntry zipkin.k8s.local
    SafeAdd-HostEntry redisinsights.k8s.local
    SafeAdd-HostEntry cockroachdb.k8s.local
    SafeAdd-HostEntry id.vonage.k8s.local

    start https://dapr.k8s.local:8443
    start https://zipkin.k8s.local:8443
    Configure-RedisInsights
    start https://cockroachdb.k8s.local:8443/
    start https://id.vonage.k8s.local:8443/ui/dashboard
}

ConfigureHostfile
ConfigureChoco
CreateCluster 
ConfigureDapr
InstallOryStack
OpenPages