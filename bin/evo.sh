#!/bin/bash
shopt -s globstar

# sfdx config:set apiVersion=54.0 --global

Clear="\033[0m"
Black="\033[0;30m"
Blackb="\033[1;30m"
White="\033[0;37m"
Whiteb="\033[1;37m"
Red="\033[0;31m"
Redb="\033[1;31m"
Green="\033[0;32m"
Greenb="\033[1;32m"
Yellow="\033[0;33m"
Yellowb="\033[1;33m"
Blue="\033[0;34m"
Blueb="\033[1;34m"
Purple="\033[0;35m"
Purpleb="\033[1;35m"
Lightblue="\033[0;36m"
Lightblueb="\033[1;36m"

setVariables () {
    CURRENT_BRANCH=$(git branch --show-current)
    if [ "$?" -ne 0 ]; then
        echo -e "ERROR ${Red}No se encuentra Git${Clear}"
        exit 1
    fi

    LOCAL_DIR=./.local
    DELTA_DIR=$LOCAL_DIR/delta
    AUTH_DIR=$LOCAL_DIR/auth
    DELTA_PACKAGE=$DELTA_DIR/package/package.xml
    DELTA_DESTRUCTIVEPACKAGE=$DELTA_DIR/destructiveChanges/destructiveChanges.xml
    #BRANCH_YEAR_MONTH=$(git show --summary --date=iso `git merge-base --octopus HEAD master` | sed -n 's/Date: *\([0-9]\{4\}\)-\([0-9]\{2\}\).*/\1\/\2/p')
    DEPLOYMENT_DIR="./branches/$CURRENT_BRANCH" # feature/${CURRENT_BRANCH#feature/}
    DEPLOYMENT_PACKAGE="$DEPLOYMENT_DIR/package.xml"
    POSTDESTRUCTIVEPACKAGE_NAME="postDestructiveChanges.xml"
    PREDESTRUCTIVEPACKAGE_NAME="preDestructiveChanges.xml"
    MAPI_DIR="mdapi"
    CONVERTED_MAPI_DIR="$DEPLOYMENT_DIR/$MAPI_DIR"
    DEPLOYMENT_PRE="$DEPLOYMENT_DIR/preDeploy.apex"
    DEPLOYMENT_POST="$DEPLOYMENT_DIR/postDeploy.apex"
    DEPLOYMENT_LOG="$DEPLOYMENT_DIR/deployment.log"
    ARTIFACT_NAME="Artifact__${CURRENT_BRANCH//\//_}.zip"
    ARTIFACT_PATH="$DEPLOYMENT_DIR/$ARTIFACT_NAME"
    #environments=("Desarrollo 1 (dev1)" "Desarrollo 2 (dev2)" "Desarrollo 3 (dev3)" "Integración/QA (int)" "UAT/Staging (uat)" "Producción (master)")
    # for i in .local/auth/*/authFile.json; do username=$(sed -n 's/.*username.*"\(.\+\)".*/\1/p' "$i"); alias=$(sed -n 's/.*alias.*"\(.\+\)".*/\1/p' "$i"); echo $alias $username; done
}

echoAliases () {
    if [ -z "$FOOJOIN" ]; then
        local aliases=()
        for i in .local/auth/*/authFile.json; do 
            if [ -s "$i" ]; then
                username=$(sed -n 's/.*username.*"\(.\+\)".*/\1/p' "$i")
                alias=$(sed -n 's/.*alias.*"\(.\+\)".*/\1/p' "$i")
                aliases+=($alias)
            fi
        done
        local SAVE_IFS="$IFS"
        IFS=", "
        FOOJOIN="${aliases[*]}"
        IFS="$SAVE_IFS"
        #echo ${aliases[@]}
    fi
    echo "$FOOJOIN"
}

branchName=""
generatePackageXml () {
    echo
    if [ -z "$1" ]; then
        read -e -p "$(echo -e "Generar ${Blue}package.xml${Clear} con el diff desde la rama actual ${Purple}${CURRENT_BRANCH}${Clear} hacia (dev1, dev2, dev3, int, uat, master...):\n ")" -i "$branchName" branchName
    else
        branchName="$1"
    fi
    local sino
    COMMIT_ANCESTOR=`git merge-base --octopus $branchName HEAD`
    if [ "$?" -ne 0 ]; then
        echo -e "ERROR ${Red}No se encuentra $branchName en Git${Clear}"
        return 1
    fi
    # echo -e "Ancestor commit $branchName --> HEAD: $COMMIT_ANCESTOR"
    #setVariables "$branchName"
    mkdir -p "$DELTA_DIR"
    echo -e "sfdx sgd:source:delta --to HEAD --from $COMMIT_ANCESTOR --repo . --output $DELTA_DIR"
    SGD_OUT=`sfdx sgd:source:delta --to HEAD --from "$COMMIT_ANCESTOR" --repo . --output "$DELTA_DIR"`
    if echo "$SGD_OUT" | grep ": true"; then
        if [ -s "$DELTA_PACKAGE" ] && [ -s "$DELTA_DESTRUCTIVEPACKAGE" ]; then
            sed -i '/<members>\./d' "$DELTA_PACKAGE" # Borrar archivos ocultos (los que comiencen por punto .)
            sed -i '/<members>\./d' "$DELTA_DESTRUCTIVEPACKAGE" 
            mkdir -p "$DEPLOYMENT_DIR/"
            cp -vf "$DELTA_PACKAGE" "$DEPLOYMENT_PACKAGE"
            echo -e "Package generado en ${Purple}${DEPLOYMENT_PACKAGE}${Clear}"
            which code >/dev/null 2>&1 && code -r "${DEPLOYMENT_PACKAGE}"

            if grep -q "<members>" "$DELTA_DESTRUCTIVEPACKAGE"; then
                cp -vf "$DELTA_DESTRUCTIVEPACKAGE" "$DEPLOYMENT_DIR/$POSTDESTRUCTIVEPACKAGE_NAME"
                echo -e "Destructive Package generado en ${Purple}$DEPLOYMENT_DIR/${POSTDESTRUCTIVEPACKAGE_NAME}${Clear}. Se ejecutará en un paso posterior al despliegue ordinario."
                which code >/dev/null 2>&1 && code -r "$DEPLOYMENT_DIR/${POSTDESTRUCTIVEPACKAGE_NAME}"
            fi
        fi
    else
        echo -e "ERROR: ${Red}No se ha podido ejecutar sgd.${Clear}" 1>&2
    fi
    # read -e -p "¿Copiar el archivo $DELTA_PACKAGE a $DEPLOYMENT_DIR [s/n]? " -i "s" sino
    # if [ "$sino" == "s" ]; then 
    #     mkdir -p "$DEPLOYMENT_DIR/"
    #     cp -vf "$DELTA_PACKAGE" "$DEPLOYMENT_DIR/"
    # fi
}

copyPackageFiles () {
    echo
    local packagePath="$1"
    if [ -z "$packagePath" ]; then
        read -e -p "$(echo -e "Preparando los archivos de despliegue desde la rama actual ${Purple}${CURRENT_BRANCH}${Clear} según el ${Blue}package.xml${Clear}:\n ")" -i $DEPLOYMENT_PACKAGE packagePath
    fi
    if [ ! -s "$packagePath" ]; then
        generatePackageXml
    fi
    if [ -s "$packagePath" ]; then
        rm -fr "$CONVERTED_MAPI_DIR"
        rm -f "$ARTIFACT_PATH"
        echo -e "sfdx force:source:convert  -r ./force-app -d $CONVERTED_MAPI_DIR --manifest $packagePath"
        sfdx force:source:convert  -r ./force-app -d "$CONVERTED_MAPI_DIR" --manifest "$packagePath"
        if [ "$?" -eq 0 ]; then
            if which zip >/dev/null 2>&1; then
                zip -r "$ARTIFACT_PATH" "$CONVERTED_MAPI_DIR" && echo -e "Creado el artefacto con zip en ${Purple}${ARTIFACT_PATH}${Clear}"
            else
                # Zip file generated with powershell is invalid
                # if which powershell >/dev/null 2>&1; then
                #     powershell Compress-Archive -Force "$CONVERTED_MAPI_DIR" "$ARTIFACT_PATH" && echo -e "Creado el artefacto con powershell en ${Purple}${ARTIFACT_PATH}${Clear}"
                # else
                    if which bestzip >/dev/null 2>&1; then
                        # npm install -g bestzip
                        echo -e "( cd $CONVERTED_MAPI_DIR/.. && bestzip $ARTIFACT_NAME $MAPI_DIR )"
                        ( 
                            cd "$CONVERTED_MAPI_DIR/.." && 
                            bestzip "$ARTIFACT_NAME" "$MAPI_DIR" && 
                            echo -e "Creado el artefacto con bestzip en ${Purple}${ARTIFACT_PATH}${Clear}"
                        )
                    else
                        echo -e "No se encuentra una orden para comprimir a ${Purple}zip${Clear}. Sugerencia:\n${Blue}npm install -g bestzip${Clear}\n "
                    fi
                #fi
            fi
            if [ -s "$ARTIFACT_PATH" ]; then
                rm -fr "$CONVERTED_MAPI_DIR"
            else
                echo -e "Creado el entregable en ${Purple}$CONVERTED_MAPI_DIR${Clear}"
            fi
        else
            echo -e "ERROR: ${Red}No se ha podido crear el entregable por un error con sfdx force:source:convert.${Clear}" 1>&2
        fi
    else
        echo -e "ERROR: ${Red}No se encuentra el archivo $packagePath.${Clear}" 1>&2
    fi
}

packagePath=""
selectPackagePath () {
    # DEPLOYMENT_PACKAGE="$DEPLOYMENT_DIR/package.xml"
    local packages=$(find ./branches/**/*package*.xml ./manifest/*.xml -printf "%T@ %Tc %p\n" | sort -n | head -30 | sed 's/.* \([^ ]\+\)/\1/g')

    local SELECTION=1
    #local ENTITIES=$(cd "${AUTH_DIR}"; ls -d */)
    for i in $packages; do
        echo -e "$SELECTION) ${i%%/}"
        ((SELECTION++))
    done
    read -e -p "$(echo -e "Indique la ruta del ${Blue}package.xml${Clear}. Deje ${Yellow}vacío${Clear} para usar toda la metadata de la rama, ignorando ${Blue}package.xml${Clear}:\n ")" -i "${DEPLOYMENT_PACKAGE}" packagePath
    if [ ! -z "$packagePath" ] && [[ `seq 1 $SELECTION` =~ "$packagePath" ]]; then
        packagePath=$(sed -n "${packagePath}p" <<< "$packages")
    fi
}

currentOrgRetrieveMetadata=""
retrieveSourceMetadata () {
    echo
    local orgName="$1"
    if [ -z "$orgName" ]; then
        if [ -z "$currentOrgRetrieveMetadata" ]; then
            local DISP=$(sfdx force:org:display 2>/dev/null )
            currentOrgRetrieveMetadata=$(echo "$DISP" | sed -n "s/Alias \+\([^\/ ]\+\).*/\1/p")
        fi
        read -e -p "$(echo -e "Indique el alias correspondiente con la org de origen ${Green}($(echoAliases))${Clear}:\n ")" -i "$currentOrgRetrieveMetadata" orgName
        [ -z "$orgName" ] || currentOrgRetrieveMetadata="$orgName"
    fi
    selectPackagePath
    if [ -s "$packagePath" ]; then
        local command="sfdx force:source:retrieve -x $packagePath -u $orgName"
        echo -e "$command"
        $command
    else
        echo -e "ERROR: ${Red}No se encuentra el archivo ${Purple}${packagePath}${Clear}.${Clear}" 1>&2
    fi
}

testList=""
currentOrgDeployMetadata=""
deployMetadata () {
    echo
    local type="$1" # source|metadata
    local orgName="$2"
    local validarDesplegar="$3"
    local runLocalTests="$4"
    if [ "$type" == "metadata" ] && [ ! -d "$CONVERTED_MAPI_DIR" ] && [ ! -s "$ARTIFACT_PATH" ]; then
        copyPackageFiles "$DEPLOYMENT_PACKAGE"
    fi
    if [ "$type" == "source" ] || [ -d "$CONVERTED_MAPI_DIR" ] || [ -s "$ARTIFACT_PATH" ]; then
        if [ -z "$orgName" ]; then
            if [ -z "$currentOrgDeployMetadata" ]; then
                local DISP=$(sfdx force:org:display 2>/dev/null )
                currentOrgDeployMetadata=$(echo "$DISP" | sed -n "s/Alias \+\([^\/ ]\+\).*/\1/p")
            fi
            read -e -p "$(echo -e "Indique el alias correspondiente con la org de destino (${Green}$(echoAliases)${Clear}):\n ")" -i "$currentOrgDeployMetadata" orgName
            [ -z "$orgName" ] || currentOrgDeployMetadata="$orgName"
        fi
        local uUserName
        local checkOnly
        local command
        local runLocalTests
        if [ -z "$orgName" ]; then
            echo -e "Usando la org por defecto para el despliegue."
        else
            uUserName=" --targetusername $orgName "
        fi
        mkdir -p "$DEPLOYMENT_DIR/"
        [ -z "$validarDesplegar" ] && read -e -p "$(echo -e "Desea validar o desplegar [v/d]:\n ")" -i "v" validarDesplegar
        echo -e "[" $(date +"%Y-%m-%dT%H:%M:%S%z") "]" >> "$DEPLOYMENT_LOG"
        if [ "$validarDesplegar" == "v" ]; then
            checkOnly=--checkonly
        else
            if [ -s "$DEPLOYMENT_PRE" ]; then
                sfdx force:apex:execute $uUserName -f "$DEPLOYMENT_PRE" 2>&1 | tee -a "$DEPLOYMENT_LOG"
            fi
        fi
        [ -z "$runLocalTests" ] && read -e -p "$(echo -e "¿Ejecutar todos los test junto con los de ${Purple}${orgName}${Clear} [s/n]? ")" -i "n" runLocalTests
        local depTest="--testlevel NoTestRun"
        if [ "$runLocalTests" == "s" ]; then 
            depTest="--testlevel RunLocalTests"
        else
            read -e -p "$(echo -e "Indique los test de la entrega. Separar por comas y sin espacios (${Blue}Enter${Clear} si no quiere ejecutar test):\n ")" -i "$testList" testList
            if [ -z "$testList" ]; then
                depTest="--testlevel NoTestRun"
            else
                depTest="--testlevel RunSpecifiedTests -r $testList"
            fi
        fi
        local commands=()
        if [ "$type" == "source" ]; then
            selectPackagePath
            if [ -z "$packagePath" ]; then
                echo -e "Desplegando toda la metadata."
                command="sfdx force:source:deploy $checkOnly --sourcepath force-app $uUserName $depTest -w 20 --verbose"
                commands+=("$command")
            else
                if [ ! -s "$packagePath" ]; then
                    echo -e "ERROR: ${Red}No se encuentra el archivo ${Purple}${packagePath}${Clear}.${Clear}" 1>&2
                    return 1
                fi
                local filename="${packagePath##*/}"
                local PACKAGEDIR=${packagePath%/*}
                echo "filename=$filename"
                echo "PACKAGEDIR=$PACKAGEDIR"
                if [ -s "${PACKAGEDIR}/$filename" ]; then
                    command="sfdx force:source:deploy $depTest $checkOnly $uUserName -x ${PACKAGEDIR}/$filename -w 20 --verbose -g "
                    
                    if [ -s "${PACKAGEDIR}/${POSTDESTRUCTIVEPACKAGE_NAME}" ]; then
                        command="$command --postdestructivechanges ${PACKAGEDIR}/${POSTDESTRUCTIVEPACKAGE_NAME}"
                    fi
                    if [ -s "${PACKAGEDIR}/${PREDESTRUCTIVEPACKAGE_NAME}" ]; then
                        command="$command --predestructivechanges ${PACKAGEDIR}/${PREDESTRUCTIVEPACKAGE_NAME}"
                    fi
                    if ! grep "<members>" "$packagePath" && ! grep "<members>" "${PACKAGEDIR}/${POSTDESTRUCTIVEPACKAGE_NAME}" && ! grep "<members>" "${PACKAGEDIR}/${PREDESTRUCTIVEPACKAGE_NAME}"; then
                        echo "WARN: No hay metadatos para desplegar a la sandbox por lo que se interrumpe el proceso." 1>&2
                        return
                    fi >/dev/null 
                    commands+=("$command")
                fi
            fi
        else
            if [ -s "$ARTIFACT_PATH" ]; then
                command="sfdx force:mdapi:deploy $depTest $checkOnly $uUserName --zipfile $ARTIFACT_PATH -w 20 --verbose"
            else
                command="sfdx force:mdapi:deploy $depTest $checkOnly $uUserName -d $CONVERTED_MAPI_DIR -w 20 --verbose"
            fi
            commands+=("$command")
        fi
        # Abrir la página de despliegues de la org destino
        echo -e "${Purple}sfdx force:org:open $uUserName -p lightning/setup/DeployStatus/home${Clear}"
        ( sfdx force:org:open $uUserName -p lightning/setup/DeployStatus/home ) &
        for command in "${commands[@]}"; do
            echo -e "${Purple}$command${Clear}" | tee -a "$DEPLOYMENT_LOG"
            $command 2>&1 | tee -a "$DEPLOYMENT_LOG"
            if [ "$?" -ne 0 ]; then 
                echo -e "ERROR: ${Red}En el despliegue.${Clear}" 1>&2
                break
            else
                if [ "$validarDesplegar" != "v" ]; then
                    if [ -s "$DEPLOYMENT_POST" ]; then
                        sfdx force:apex:execute -u "$orgName" -f "$DEPLOYMENT_POST" 2>&1 | tee -a "$DEPLOYMENT_LOG"
                    fi
                fi
            fi
        done
    else
        echo -e "ERROR: ${Red}No existe el directorio $CONVERTED_MAPI_DIR o el archivo de artefacto $ARTIFACT_PATH.${Clear}" 1>&2
    fi
    if [ -s "$DEPLOYMENT_LOG" ]; then
        echo >> $DEPLOYMENT_LOG
        echo -e "Creado un archivo de log en ${Purple}${DEPLOYMENT_LOG}${Clear}."
    fi
}

openOrg () {
    echo
    local orgBranch="$1"
    if [ -z "$orgBranch" ]; then
        # Muestra una lista de alias de autorizaciones locales
        local SELECTION=1
        local ENTITIES=$(cd "${AUTH_DIR}"; ls -d */)
        local username
        for i in $ENTITIES; do
            local filepath="${AUTH_DIR}/${i%%/}/authFile.json"
            if [ -s "$filepath" ]; then
                username=$(sed -n 's/.*username.*"\(.\+\)".*/\1/p' "$filepath")
                echo -e "$SELECTION) ${Green}${i%%/}${Clear} - $username"
                ((SELECTION++))
            fi
        done
        echo -e "$SELECTION) Salir."
        echo -e "Indique el alias de la org a abrir (dejar vacío para abrir la org por defecto): "
        read -r orgBranch
        if [ -z "$orgBranch" ]; then
            if ! sfdx force:org:open; then
                echo -e "ERROR: ${Red}No se puede abrir la org por defecto.${Clear}" 1>&2
            else
                echo -e "Para subir la rama actual a la org utilice la siguiente orden:\n${Purple}sfdx force:source:push --ignorewarnings${Clear}"
                echo -e "Para bajar la metadata de la org y sobreescribir la actual, utilice la siguiente orden:\n${Purple}sfdx force:source:pull --forceoverwrite${Clear}"
                
                echo -e "Para restablecer el seguimiento de fuentes locales y remotas, utilice la siguiente orden:\n${Purple}sfdx force:source:tracking:reset -u \"$orgBranch\" ${Clear}"
                echo -e "Para borrar toda la información de seguimiento de fuentes locales, utilice la siguiente orden:\n${Purple}sfdx force:source:tracking:clear -u \"$orgBranch\" ${Clear}"
            fi
            return
        fi
        if [ "$orgBranch" == q ] || [ "$orgBranch" == "$SELECTION" ]; then
            return
        fi
        if [[ `seq 1 $SELECTION` =~ $orgBranch ]]; then
            orgBranch=$(sed -n "${orgBranch}p" <<< "$ENTITIES")
            orgBranch=${orgBranch%%/}
        fi
    fi
    #sfdx auth:logout -u "$orgBranch"
    echo -e "Seleccionada la org ${Green}$orgBranch${Clear}."
    local authFile="$AUTH_DIR/$orgBranch/authFile.json"
    # Abre la org desde el archivo local si existe.
    if [ -s "$authFile" ]; then
        echo -e " ${Purple}sfdx auth:sfdxurl:store -f $authFile -a $orgBranch -s${Clear}"
        local mess=$(sfdx auth:sfdxurl:store -f "$authFile" -a "$orgBranch" -s)
        if ! echo "$mess" | grep Success; then
            echo -e "ERROR: ${Red}No se puede abrir la org mediante el archivo de autorización local.${Clear}" 1>&2
            echo -e "¿Desea borrar el archivo de autorización ${Purple}${authFile}${Clear} [s/n]?"
            local sino
            read -e sino
            if [ "$sino" != "n" ]; then
                rm -rf "$AUTH_DIR/$orgBranch" && echo -e "Borrado ${Purple}$AUTH_DIR/${orgBranch}${Clear}."
            fi
            return
        fi
    fi
    echo -e "${Purple}sfdx force:org:open -u $orgBranch${Clear}"
    if ! sfdx force:org:open -u "$orgBranch"; then
        echo -e "ERROR: ${Red}No se puede abrir la org porque no está autorizada o no existe un archivo de autorización válido en $authFile.${Clear}" 1>&2
    else
        echo -e "Para subir la rama actual a la org utilice la siguiente orden:\n${Purple}sfdx force:source:push -u \"$orgBranch\" --ignorewarnings${Clear}"
        echo -e "Para bajar la metadata de la org y sobreescribir la actual, utilice la siguiente orden:\n${Purple}sfdx force:source:pull -u \"$orgBranch\" --forceoverwrite${Clear}"
    fi
}

authOrg () {
    echo
    local orgBranch="$1"
    if [ -z "$orgBranch" ]; then
        read -e -p "Indique la org que desea autorizar: " -i "develop" orgBranch
    fi
    local instanceurl
    local sino
    if [ -s $AUTH_DIR/$orgBranch/authFile.json ]; then
        read -e -p "$(echo -e "Ya existe un archivo de autorización para la org vinculada a la rama ${Green}${orgBranch}${Clear}. ¿Desea sobreescribirla [s/n]? ")" -i "s" sino
        [ "$sino" == "n" ] && return
    fi
    echo -e "Autenticando una org con el Alias ${Green}${orgBranch}${Clear}"
    read -e -p "Indique la URL de la instancia: " -i "https://test.salesforce.com" instanceurl
    sfdx auth:web:login -s -r "$instanceurl" -a $orgBranch
    mkdir -p $AUTH_DIR/$orgBranch
    sfdx force:org:display -u "$orgBranch" --verbose --json > $AUTH_DIR/$orgBranch/authFile.json
    echo -e "Credenciales guardadas en ${Purple}$AUTH_DIR/$orgBranch/authFile.json${Clear}"
    echo -e "Para revocar el login ejecute ${Purple}sfdx force:auth:logout -u \"$orgBranch\"${Clear}"
    # sfdx auth:sfdxurl:store -f authFile.json -a dev1
    # sfdx force:org:open -u dev1
    #
    # LOGIN_INFO=$(sfdx force:org:display -u dev1 --verbose)
    # echo -n $LOGIN_INFO | sed 's|.*\(force:.*\)|\1|' > url_login.txt
    # sfdx force:auth:sfdxurl:store -f url_login.txt -d -a Hub_Org
}

branchPromotion () {
    echo
    # Test if git is working properly
    local gitping=$(git ls-remote -h origin 2>&1 )
    if [ "$?" -ne 0 ]; then
        echo -e "ERROR: ${Red}No hay comunicación con el repositorio remoto.${Clear}" 1>&2
        return 1
    fi
    local branchName="$1"
    if [ -z "$branchName" ]; then
        read -e -p "$(echo -e "Seleccione la rama de destino del ${Blackb}Pull-Request${Clear} a la que añadirá el contenido de la rama actual ${Purple}${CURRENT_BRANCH}${Clear} (dev1, dev2, dev3, int, uat, master...):\n ")" -i "int" branchName
    fi
    promotionBranch=promotion/${branchName//\//_}/${CURRENT_BRANCH//\//_}
    echo -e "Rama de promoción: ${Purple}${promotionBranch}${Clear}"
    if ! git ls-remote --heads origin "${branchName}"; then 
        echo -e "La rama destino ${Purple}$branchName${Clear} no existe en el repositorio."
        return 1
    fi
    if ! git checkout "${branchName}"; then
        echo -e "No es posible conmutar a la rama ${Purple}$branchName${Clear}."
        return 1
    fi
    git pull
    if ! git checkout -B "${promotionBranch}"; then
        echo -e "No es posible conmutar a la rama de promoción ${Purple}$promotionBranch${Clear}."
        return 1
    fi
    if [[ -z $(git ls-remote --heads origin ${promotionBranch}) ]]; then 
        echo -e "git merge ${branchName}"
        if ! git merge "${branchName}"; then
            while [ $(git ls-files -u | wc -l) -gt 0 ]; do
                echo -e "Solucione los conflictos del: git merge ${Purple}${branchName}${Clear}"       
                read -p "Presione [Enter]"
            done
        fi
        if ! git merge "${CURRENT_BRANCH}"; then
            while [ $(git ls-files -u | wc -l) -gt 0 ]; do
                echo -e "Solucione los conflictos del: git merge ${Purple}${CURRENT_BRANCH}${Clear}"       
                read -p "Presione [Enter]"
            done
        fi
        git push --set-upstream origin "${promotionBranch}"
        echo -e "Creada la rama de promoción ${Purple}origin ${promotionBranch}${Clear}"
    else
        git pull
        if ! git merge "${CURRENT_BRANCH}"; then                
            return 1
        fi
        git push
        echo -e "Actualizada la rama de promoción ${Purple}origin${promotionBranch}${Clear}"
    fi
    git checkout ${CURRENT_BRANCH}

}

deleteScratchOrg () {
    local orgAlias="$1"
    local devHubAlias="$2"
    if [ -z "$orgAlias" ]; then
        read -e -p "$(echo -e "Indique el alias correspondiente a la org de destino (${Green}$(echoAliases)${Clear}):\n ")" -i "" orgAlias
    fi
    if [ -z "$devHubAlias" ]; then
        read -e -p "$(echo -e "Indique el alias correspondiente a la DevHub org:\n ")" -i "devHub" devHubAlias
    fi
    if [ ! -z "$orgAlias" ]; then
        echo -e "${Purple}sfdx force:org:delete -u \"$orgAlias\" -v $devHubAlias ${Clear}"
        sfdx force:org:delete -u "$orgAlias" -v "$devHubAlias" && rm -rf "$AUTH_DIR/$orgAlias" && echo -e "Borrado ${Purple}$AUTH_DIR/${orgAlias}${Clear}."
    fi
}

createScratchOrg () {
    echo
    local devhubOrg
    local scratchFile="config/project-scratch-def.json"
    if ! git diff-index --quiet HEAD; then
        echo -e "${Red}ERROR: Para crear una ScratchOrg no pueden haber archivos modificados en la rama.${Clear}" 1>&2
        return 1
    fi
    echo -e "Alias de orgs actuales (${Green}$(echoAliases)${Clear})."
    read -e -p "Escriba el alias de la nueva Scratch Org: " -i "scratchOrg1" orgAlias
    if [ -s $AUTH_DIR/"$orgAlias"/authFile.json ]; then
        read -e -p "$(echo -e "Ya existen credenciales almacenadas para ${Blue}${orgAlias}${Clear}. ¿Desea sobreescribirlas [s/n]? ")" -i "s" sino
        [ "$sino" == "n" ] && return
    fi
    read -e -p "$(echo -e "Indique el nombre de la Org anfitrión DevHub:\n ")" -i "devHub" devhubOrg
    # Usar con prioridad el archivo de usuario
    [ -s "config/.project-scratch-def.json" ] && scratchFile="config/.project-scratch-def.json"
    # read -e -p "Indique la ruta del archivo de definición de la ScratchOrg: " -i "config/project-scratch-def.json" scratchFile
    echo -e "Espere unos minutos mientras se crea la ScratchOrg..."
    
    local gitEmail="$(git config user.email)" # TimeZoneSidKey
    local gitUser="$(git config user.name)"
    if [ -z "$gitEmail" ]; then
        echo -e "WARN: No se ha definido el email del usuario de Git. Ejecute la siguiente orden:\n${Purple}git config --global user.email nombre.apellido@evolutio.com${Clear}" 1>&2
        gitEmail=""
    else
        gitEmail="adminEmail=$gitEmail"
    fi
    if [ -z "$gitUser" ]; then
        echo -e "WARN: No se ha definido el nombre del usuario de Git. Ejecute la siguiente orden:\n${Purple}git config --global user.name \"Nombre Apellido\"${Clear}" 1>&2
        gitUser=""
    else
        gitUser="de $gitUser"
    fi
    # sfdx force:data:record:create -u test-kklzgqn0jcca@example.com -s User -v "Alias='testA' Email='my@email.com' EmailEncodingKey='ISO-8859-1'  LastName='Testing' ProfileId='**StdUserProfID**' UserName='scratchTestBySFDX@testSFDX.SFDX.test' TimeZoneSidKey='America/Los_Angeles' LanguageLocaleKey='en_US' LocaleSidKey='en_US'"
    local command="sfdx force:org:create -s -f $scratchFile -v $devhubOrg -a $orgAlias --durationdays 30 $gitEmail orgName=$orgAlias "
    echo -e "${Purple}${command} description=\"${gitUser} - Rama: ${CURRENT_BRANCH}\"${Clear}" # timeZoneSidKey='Europe/Madrid'
    ${command} description="${gitUser} - Rama: ${CURRENT_BRANCH}"
    if [ "$?" -eq 0 ]; then
        echo -e "${Purple}sfdx force:org:open -u \"${orgAlias}\"${Clear}"
        ( sfdx force:org:open -u "$orgAlias" -p lightning/setup/DeployStatus/home ) &
        mkdir -p "$AUTH_DIR/$orgAlias"
        sfdx force:org:display -u "$orgAlias" --verbose --json > "$AUTH_DIR/$orgAlias"/authFile.json
        echo -e "Credenciales guardadas en ${Purple}$AUTH_DIR/$orgAlias/authFile.json${Clear}"
        
        # Ejecutar el post-script con el contexto actual
        [ -s config/project-scratch-postcreation.sh ] && source config/project-scratch-postcreation.sh "$orgAlias" "${CURRENT_BRANCH}"

        sfdx force:org:open -u "$orgAlias" -r

        echo -e "Para subir la rama actual a la org, utilice la siguiente orden:\n${Purple}sfdx force:source:push -u \"$orgAlias\" -f --ignorewarnings${Clear}"
        echo -e "Para bajar la metadata de la org y sobreescribir la actual, utilice la siguiente orden:\n${Purple}sfdx force:source:pull -u \"$orgAlias\" --forceoverwrite${Clear}"

        
        echo -e "Para restablecer el seguimiento de fuentes locales y remotas, utilice la siguiente orden:\n${Purple}sfdx force:source:tracking:reset -u \"$orgBranch\" ${Clear}"
        echo -e "Para borrar toda la información de seguimiento de fuentes locales, utilice la siguiente orden:\n${Purple}sfdx force:source:tracking:clear -u \"$orgBranch\" ${Clear}"
    else
        echo -e "ERROR: ${Red}No se ha podido crear la Scratch Org.${Clear}" 1>&2
    fi
    # read -e -p "¿Desea abrir ahora la ScratchOrg "$orgAlias" [s/n]? " -i "s" sino
    # if [ "$sino" == "s" ]; then
    #     sfdx force:org:open -u "$orgAlias"
    # else
    #     sfdx force:org:open -u "$orgAlias" -r
    # fi
}

setVariables

# main menu
echo -e "Gestión de despliegues de Evolutio.\nRama actual ${Purple}${CURRENT_BRANCH}${Clear}"
PS3="$(echo -e "Seleccione una opción (${Purple}${CURRENT_BRANCH}${Clear}):\n ")"
options=("Autorizar una org." "Abrir una org y seleccionarla por defecto." "Crear una Scratch Org." "Borrar una Scratch Org." "$(echo -e "Generar ${Blue}package.xml${Clear} para el despliegue.")" "$(echo -e "Descargar la metadata que indica el ${Blue}package.xml${Clear} desde la Org en formato ${Yellow}source${Clear}.")" "$(echo -e "Validar o Desplegar el entregable ${Blue}package.xml${Clear} desde el ${Yellow}source${Clear} actual.")" "$(echo -e "Preparar el entregable correspondiente al ${Blue}package.xml${Clear} en formato ${Yellow}metadata${Clear}.")" "$(echo -e "Validar o Desplegar el entregable actual de la rama en formato ${Yellow}metadata${Clear}.")" "$(echo -e "Crear o actualizar rama de ${Blackb}Pull-Request${Clear}.")" "Logout" "Salir.")
select opt in "${options[@]}"
do
    setVariables
    case "$REPLY" in
        1) authOrg ;;
        2) openOrg ;;
        3) createScratchOrg ;;
        4) deleteScratchOrg ;;
        5) generatePackageXml ;;
        6) retrieveSourceMetadata ;;
        7) deployMetadata "source" ;;
        8) copyPackageFiles ;;
        9) deployMetadata "metadata" ;;
        10) ( branchPromotion ) ;; # launch in a subshell
        11) sfdx auth:logout --all ;;
        12) exit ;;
        *) 
            if [ "$REPLY" == "q" ]; then 
                exit
            else
                echo -e "Opción inválida, pruebe otra" 
            fi
            ;;
    esac
done