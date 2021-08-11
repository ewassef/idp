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
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
    Start-Sleep -Seconds 5
    kubectl wait --namespace ingress-nginx --for=condition=ready --selector=app.kubernetes.io/component=controller pod --timeout=240s
    
}

function ConfigureHostfile(){
    if ($(Test-CommandExists Add-HostEntry) -eq $false){
        Install-Module pshosts
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

    #install Redis first
    helm install redis bitnami/redis
    #create the identity namespace
    kubectl create ns identity
    #install the dapr helpers
    kubectl apply -f .\dapr.yaml
    kubectl apply -f .\dapr.yaml

}

function InstallOryStack(){


#install cockroach 
helm install cockroach cockroachdb/cockroachdb -n identity --set ingress.enabled=true --set ingress.hosts[0]=cockroach.k8s.local
kubectl wait --for=condition=ready --selector=app.kubernetes.io/component=cockroachdb pod -n identity --timeout=240s
#create the dbs
kubectl run -it --rm cockroach-client --image=cockroachdb/cockroach --restart=Never --command -- ./cockroach sql --insecure --host=cockroach-cockroachdb-public.identity -e "CREATE DATABASE HYDRA;CREATE DATABASE KRATOS;CREATE DATABASE KETO;SHOW DATABASES"
 
#install kratos
helm pull ory/kratos -d .\Ory\Kratos --version 0.19.0
helm install kratos .\Ory\Kratos\kratos-0.19.0.tgz -f .\Ory\Kratos\values.yaml -n identity
#install sample UI
helm pull ory/kratos-selfservice-ui-node -d .\Ory\Kratos --version 0.19.0
helm install kratos-ui .\Ory\Kratos\kratos-selfservice-ui-node-0.19.0.tgz -f .\Ory\Kratos\ui-values.yaml -n identity
#install hydra
helm pull ory/hydra -d .\Ory\Hydra --version 0.19.0
helm install hydra .\Ory\Hydra\hydra-0.19.0.tgz -f .\Ory\Hydra\values.yaml -n identity
#install keto
helm pull ory/keto -d .\Ory\Keto --version 0.19.0
helm install keto .\Ory\Keto\keto-0.19.0.tgz -f .\Ory\Keto\values.yaml -n identity

}

function Configure-RedisInsights(){

    $secret = kubectl get secret redis -o jsonpath="{..redis-password}"
    $secret = [System.Text.Encoding]::Default.GetString([System.Convert]::FromBase64String($secret))
    $uri = "https://redisinsights.k8s.local:8443/add/?name=Vonage IAM Redis&host=redis-master&port=6379&password=$($secret)&redirect=true"
     
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


    start https://dapr.k8s.local:8443
    start https://zipkin.k8s.local:8443
    Configure-RedisInsights
    start https://cockroachdb.k8s.local:8443/
}

ConfigureHostfile
ConfigureChoco
CreateCluster
ConfigureDapr
InstallOryStack