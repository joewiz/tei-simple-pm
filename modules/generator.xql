(:
 : Copyright 2015, Wolfgang Meier
 :
 : This software is dual-licensed:
 :
 : 1. Distributed under a Creative Commons Attribution-ShareAlike 3.0 Unported License
 : http://creativecommons.org/licenses/by-sa/3.0/
 :
 : 2. http://www.opensource.org/licenses/BSD-2-Clause
 :
 : All rights reserved. Redistribution and use in source and binary forms, with or without
 : modification, are permitted provided that the following conditions are met:
 :
 : * Redistributions of source code must retain the above copyright notice, this list of
 : conditions and the following disclaimer.
 : * Redistributions in binary form must reproduce the above copyright
 : notice, this list of conditions and the following disclaimer in the documentation
 : and/or other materials provided with the distribution.
 :
 : This software is provided by the copyright holders and contributors "as is" and any
 : express or implied warranties, including, but not limited to, the implied warranties
 : of merchantability and fitness for a particular purpose are disclaimed. In no event
 : shall the copyright holder or contributors be liable for any direct, indirect,
 : incidental, special, exemplary, or consequential damages (including, but not limited to,
 : procurement of substitute goods or services; loss of use, data, or profits; or business
 : interruption) however caused and on any theory of liability, whether in contract,
 : strict liability, or tort (including negligence or otherwise) arising in any way out
 : of the use of this software, even if advised of the possibility of such damage.
 :)
xquery version "3.1";

import module namespace tmpl="http://exist-db.org/xquery/template" at "tmpl.xql";
import module namespace config="http://www.tei-c.org/tei-simple/config" at "config.xqm";
import module namespace pmu="http://www.tei-c.org/tei-simple/xquery/util" at "/db/apps/tei-simple/content/util.xql";
import module namespace odd="http://www.tei-c.org/tei-simple/odd2odd" at "/db/apps/tei-simple/content/odd2odd.xql";

declare namespace deploy="http://www.tei-c.org/tei-simple/generator";
declare namespace git="http://exist-db.org/eXide/git";
declare namespace expath="http://expath.org/ns/pkg";
declare namespace repo="http://exist-db.org/xquery/repo";
declare namespace output="http://www.w3.org/2010/xslt-xquery-serialization";

declare option output:method "json";
declare option output:media-type "application/javascript";

declare variable $deploy:app-root := request:get-attribute("app-root");

declare variable $deploy:ANT_FILE :=
    <project default="xar" name="$$app$$">
        <xmlproperty file="expath-pkg.xml"/>
        <property name="project.version" value="${{package(version)}}"/>
        <property name="project.app" value="$$app$$"/>
        <property name="build.dir" value="build"/>
        <target name="xar">
            <mkdir dir="${{build.dir}}"/>
            <zip basedir="." destfile="${{build.dir}}/${{project.app}}-${{project.version}}.xar"
                excludes="${{build.dir}}/*"/>
        </target>
    </project>;

declare function deploy:xconf($collection as xs:string, $odd as xs:string, $userData as xs:string*, $permissions as xs:string?) {
    let $xconf :=
        <collection xmlns="http://exist-db.org/collection-config/1.0">
            <index xmlns:tei="http://www.tei-c.org/ns/1.0" xmlns:xs="http://www.w3.org/2001/XMLSchema">
                <fulltext default="none" attributes="false"/>
                <lucene>
                    <text qname="tei:div"/>
                    <text qname="tei:head"/>
                    <text match="//tei:sourceDesc/tei:biblFull/tei:titleStmt/tei:title"/>
                    <text match="//tei:fileDesc/tei:titleStmt/tei:title"/>
                </lucene>
            </index>
            <!--triggers>
                <trigger event="update" class="org.exist.collections.triggers.XQueryTrigger">
                    <parameter name="url" value="xmldb:exist://{$collection}/modules/on-odd-changed.xql"/>
                    <parameter name="odd" value="{$odd}"/>
                    <parameter name="collection" value="{$collection}"/>
                </trigger>
            </triggers-->
        </collection>
    return (
        xmldb:store($collection, "collection.xconf", $xconf),
        deploy:mkcol("/db/system/config" || $collection, $userData, $permissions),
        xmldb:store("/db/system/config" || $collection, "collection.xconf", $xconf)
    )
};

(: Handle difference between 4.x.x and 5.x.x releases of eXist :)
declare variable $deploy:copy-resource :=
    let $fnNew := function-lookup(xs:QName("xmldb:copy-resource"), 4)
    return
        if (exists($fnNew)) then
            $fnNew
        else
            let $fnOld := function-lookup(xs:QName("xmldb:copy"), 3)
            return
                function($sourceCol, $sourceName, $targetCol, $targetName) {
                    $fnOld($sourceCol, $targetCol, $sourceName)
                };


declare function deploy:init-simple($collection as xs:string?, $userData as xs:string*, $permissions as xs:string?) {
    let $target := $collection || "/resources/odd"
    let $odd := request:get-parameter("odd", "teisimple.odd")
    let $mkcol := deploy:mkcol($target, $userData, $permissions)
    return (
        deploy:xconf($collection, $odd, $userData, $permissions),
        for $file in ("elementsummary.xml", "headerelements.xml", "headeronly.xml", "simpleelements.xml", "teisimple.odd", $odd, "configuration.xml")
        return (
            $deploy:copy-resource($config:odd-root, $file, $target, $file),
            if (exists($userData)) then
                let $stored := xs:anyURI($target || "/" || $file)
                return (
                    sm:chmod($stored, $permissions),
                    sm:chown($stored, $userData[1]),
                    sm:chgrp($stored, $userData[2])
                )
            else
                ()
        ),
        deploy:mkcol($target || "/compiled", $userData, $permissions),
        (: $deploy:copy-resource($config:compiled-odd-root, "teisimple.odd", $target || "/compiled", "teisimple.odd"), :)
        deploy:mkcol($collection || "/data", $userData, $permissions),
        deploy:mkcol($collection || "/transform", $userData, $permissions),
        $deploy:copy-resource($config:output-root, "teisimple.fo.css", $collection || "/transform", "teisimple.fo.css"),
        deploy:chmod-scripts($collection)
    )
};

declare function deploy:chmod-scripts($target as xs:string) {
    sm:chmod(xs:anyURI($target || "/modules/view.xql"), "rwsr-xr-x"),
    sm:chmod(xs:anyURI($target || "/modules/ajax.xql"), "rwsr-xr-x"),
    sm:chmod(xs:anyURI($target || "/modules/regenerate.xql"), "rwsr-xr-x")
};

declare function deploy:store-expath($collection as xs:string?, $userData as xs:string*, $permissions as xs:string?) {
    let $descriptor :=
        <package xmlns="http://expath.org/ns/pkg"
            name="{request:get-parameter('uri', ())}" abbrev="{request:get-parameter('abbrev', ())}"
            version="{request:get-parameter('version', '0.1')}" spec="1.0">
            <title>{request:get-parameter("title", ())}</title>
            <dependency package="http://exist-db.org/apps/shared"/>
            <dependency package="http://www.tei-c.org/tei-simple"/>
        </package>
    return (
        xmldb:store($collection, "expath-pkg.xml", $descriptor, "text/xml"),
        let $targetPath := xs:anyURI($collection || "/expath-pkg.xml")
        return (
            sm:chmod($targetPath, $permissions),
            sm:chown($targetPath, $userData[1]),
            sm:chgrp($targetPath, $userData[2])
        )
    )
};

declare function deploy:repo-descriptor($target as xs:string) {
    <meta xmlns="http://exist-db.org/xquery/repo">
        <description>
        {
            let $desc := request:get-parameter("description", ())
            return
                if ($desc) then $desc else request:get-parameter("title", ())
        }
        </description>
        {
            for $author in request:get-parameter("author", ())
            return
                <author>{$author}</author>
        }
        <website>{request:get-parameter("website", ())}</website>
        <status>{request:get-parameter("status", ())}</status>
        <license>GNU-LGPL</license>
        <copyright>true</copyright>
        <type>{request:get-parameter("type", "application")}</type>
        <target>{$target}</target>
        <prepare>pre-install.xql</prepare>
        <finish>post-install.xql</finish>
        {
            let $owner := request:get-parameter("owner", ())
            return
                if ($owner and $owner != "") then
                    let $group := request:get-parameter("group", $owner)
                    return
                        <permissions user="{$owner}"
                            password="{request:get-parameter('password', ())}"
                            group="{if ($group != '') then $group else 'dba'}"
                            mode="rw-rw-r--"/>
                else
                    ()
        }
    </meta>
};

declare function deploy:store-repo($descriptor as element(), $collection as xs:string?, $userData as xs:string*, $permissions as xs:string?) {
    (
        xmldb:store($collection, "repo.xml", $descriptor, "text/xml"),
        let $targetPath := xs:anyURI($collection || "/repo.xml")
        return (
            sm:chmod($targetPath, $permissions),
            sm:chown($targetPath, $userData[1]),
            sm:chgrp($targetPath, $userData[2])
        )
    )
};

declare function deploy:mkcol-recursive($collection, $components, $userData as xs:string*, $permissions as xs:string?) {
    if (exists($components)) then
        let $permissions :=
            if ($permissions) then
                deploy:set-execute-bit($permissions)
            else
                "rwxr-x---"
        let $newColl := xs:anyURI(concat($collection, "/", $components[1]))
        return (
            xmldb:create-collection($collection, $components[1]),
            if (exists($userData)) then (
                sm:chmod($newColl, $permissions),
                sm:chown($newColl, $userData[1]),
                sm:chgrp($newColl, $userData[2])
            ) else
                (),
            deploy:mkcol-recursive($newColl, subsequence($components, 2), $userData, $permissions)
        )
    else
        ()
};

declare function deploy:mkcol($path, $userData as xs:string*, $permissions as xs:string?) {
    let $path := if (starts-with($path, "/db/")) then substring-after($path, "/db/") else $path
    return
        deploy:mkcol-recursive("/db", tokenize($path, "/"), $userData, $permissions)
};

declare function deploy:create-collection($collection as xs:string, $userData as xs:string+, $permissions as xs:string) {
    let $target := collection($collection)
    return
        if ($target) then
            $target
        else
            deploy:mkcol($collection, $userData, $permissions)
};

declare function deploy:check-group($group as xs:string) {
    if (sm:group-exists($group)) then
        ()
    else
        sm:create-group($group)
};

declare function deploy:check-user($repoConf as element()) as xs:string+ {
    let $perms := $repoConf/repo:permissions
    let $user := if ($perms/@user) then $perms/@user/string() else sm:id()/sm:id/sm:real/sm:username/string()
    let $group := if ($perms/@group) then $perms/@group/string() else sm:get-user-groups($user)[1]
    let $create :=
        if (sm:user-exists($user)) then
            if (index-of(sm:get-user-groups($user), $group)) then
                ()
            else (
                deploy:check-group($group),
                sm:add-group-member($user, $group)
            )
        else (
            deploy:check-group($group),
            sm:create-account($user, $perms/@password, $group, ())
        )
    return
        ($user, $group)
};

declare function deploy:target-permissions($repoConf as element()) as xs:string {
    let $permissions := $repoConf/repo:permissions/@mode/string()
    return
        if ($permissions) then
            if ($permissions castable as xs:int) then
                sm:octal-to-mode(util:base-to-integer(xs:int($permissions), 8))
            else
                $permissions
        else
            "rw-rw-r--"
};

declare function deploy:set-execute-bit($permissions as xs:string) {
    replace($permissions, "(..).(..).(..).", "$1x$2x$3x")
};

declare function deploy:copy-templates($target as xs:string, $source as xs:string, $userData as xs:string+, $permissions as xs:string) {
    let $null := deploy:mkcol($target, $userData, $permissions)
    return
    if (exists(collection($source))) then (
        for $resource in xmldb:get-child-resources($source)
        let $targetPath := xs:anyURI(concat($target, "/", $resource))
        return (
            $deploy:copy-resource($source, $resource, $target, $resource),
            let $mime := xmldb:get-mime-type($targetPath)
            let $perms :=
                if ($mime eq "application/xquery") then
                    deploy:set-execute-bit($permissions)
                else $permissions
            return (
                sm:chmod($targetPath, $perms),
                sm:chown($targetPath, $userData[1]),
                sm:chgrp($targetPath, $userData[2])
            )
        ),
        for $childColl in xmldb:get-child-collections($source)
        return
            deploy:copy-templates(concat($target, "/", $childColl), concat($source, "/", $childColl), $userData, $permissions)
    ) else
        ()
};

declare function deploy:store-templates-from-db($target as xs:string, $base as xs:string, $userData as xs:string+, $permissions as xs:string) {
    let $template := request:get-parameter("template", "basic")
    let $templateColl := concat($base, "/templates/", $template)
    return
        deploy:copy-templates($target, $templateColl, $userData, $permissions)
};

declare function deploy:chmod($collection as xs:string, $userData as xs:string+, $permissions as xs:string) {
    (
        let $collURI := xs:anyURI($collection)
        return (
            sm:chmod($collURI, $permissions),
            sm:chown($collURI, $userData[1]),
            sm:chgrp($collURI, $userData[2])
        ),
        for $resource in xmldb:get-child-resources($collection)
        let $path := concat($collection, "/", $resource)
        let $targetPath := xs:anyURI($path)
        let $mime := xmldb:get-mime-type($path)
        let $perms :=
            if ($mime eq "application/xquery") then
                deploy:set-execute-bit($permissions)
            else
                $permissions
        return (
            sm:chmod($targetPath, $permissions),
            sm:chown($targetPath, $userData[1]),
            sm:chgrp($targetPath, $userData[2])
        ),
        for $child in xmldb:get-child-collections($collection)
        return
            deploy:chmod(concat($collection, "/", $child), $userData, $permissions)
    )
};

declare function deploy:store-ant($target as xs:string, $permissions as xs:string) {
    let $abbrev := request:get-parameter("abbrev", "")
    let $parameters :=
        <parameters>
            <param name="app" value="{$abbrev}"/>
        </parameters>
    let $antXML := tmpl:expand-template($deploy:ANT_FILE, $parameters)
    return
        xmldb:store($target, "build.xml", $antXML)
};

declare function deploy:expand($collection as xs:string, $resource as xs:string, $parameters as element(parameters)) {
    if (util:binary-doc-available($collection || "/" || $resource)) then
        let $code :=
            let $doc := util:binary-doc($collection || "/" || $resource)
            return
                util:binary-to-string($doc)
        let $expanded := tmpl:parse($code, $parameters)
        return
            xmldb:store($collection, $resource, $expanded)
    else
        ()
};

declare function deploy:expand-xql($target as xs:string) {
    let $name := request:get-parameter("uri", ())
    let $odd := request:get-parameter("odd", "teisimple.odd")
    let $defaultView := request:get-parameter("default-view", "div")
    let $data-param := request:get-parameter("data-collection", ())
    let $data-param :=
        if (ends-with($data-param, "/")) then $data-param else $data-param || "/"
    let $data-root :=
        if ($data-param eq "/") then
            '$config:app-root || "/data"'
        else
            '"' || $data-param || '"'
    let $parameters :=
        <parameters>
            <param name="templates" value=""/>
            <param name="namespace" value="{$name}/templates"/>
            <param name="config-namespace" value="{$name}/config"/>
            <param name="pages-namespace" value="{$name}/pages"/>
            <param name="default-view" value="{$defaultView}"/>
            <param name="config-data" value="{$data-root}"/>
            <param name="config-odd" value="{$odd}"/>
            <param name="config-odd-name" value="{substring-before($odd, '.odd')}"/>
        </parameters>
    for $module in ("config.xqm", "pm-config.xql")
    return
        deploy:expand($target || "/modules", $module, $parameters)
};

declare function deploy:store-templates-from-fs($target as xs:string, $base as xs:string, $userData as xs:string+, $permissions as xs:string) {
    let $pathSep := util:system-property("file.separator")
    let $template := request:get-parameter("template", "basic")
    let $templatesDir := concat($base, $pathSep, "templates", $pathSep, $template)
    return (
        xmldb:store-files-from-pattern($target, $templatesDir, "**/*", (), true(), "**/.svn/**"),
        deploy:chmod($target, $userData, $permissions)
    )
};

declare function deploy:store-templates($target as xs:string, $userData as xs:string+, $permissions as xs:string) {
    let $base := substring-before(system:get-module-load-path(), "/modules")
    return (
        if (starts-with($base, "xmldb:exist://")) then
            deploy:store-templates-from-db($target, $base, $userData, $permissions)
        else
            deploy:store-templates-from-fs($target, $base, $userData, $permissions)
    )
};

declare function deploy:store($collection as xs:string?, $target as xs:string, $expathConf as element()?) {
    let $collection :=
        if (starts-with($collection, "/")) then
            $collection
        else
            repo:get-root() || $collection
    let $repoConf := deploy:repo-descriptor($target)
    let $permissions := deploy:target-permissions($repoConf)
    let $userData := deploy:check-user($repoConf)
    return
        if (not($collection)) then
            error(QName("http://exist-db.org/xquery/sandbox", "missing-collection"), "collection parameter missing")
        else
            let $create := deploy:create-collection($collection, $userData, $permissions)
            let $null := (
                deploy:store-expath($collection, $userData, $permissions),
                deploy:store-repo($repoConf, $collection, $userData, $permissions),
                if (empty($expathConf)) then (
                    deploy:store-templates($collection, $userData, $permissions),
                    deploy:store-ant($collection, $permissions),
                    deploy:expand-xql($collection)
                ) else
                    (),
                deploy:init-simple($collection, $userData, $permissions)
            )
            return
                $collection
};

declare function deploy:create-app($collection as xs:string?, $target as xs:string, $expathConf as element()?) {
    let $collection := deploy:store($collection, $target, $expathConf)
    return
        if (empty($expathConf)) then
            let $expathConf := doc($collection || "/expath-pkg.xml")/*
            return (
                deploy:deploy($collection, $expathConf),
                $collection
            )
        else
            $collection
};

declare function deploy:package($collection as xs:string, $expathConf as element()) {
    let $name := concat($expathConf/@abbrev, "-", $expathConf/@version, ".xar")
    let $xar := compression:zip(xs:anyURI($collection), true(), $collection)
    let $mkcol := deploy:mkcol("/db/system/repo", (), ())
    return
        xmldb:store("/db/system/repo", $name, $xar, "application/zip")
};

declare function deploy:deploy($collection as xs:string, $expathConf as element()) {
    let $pkg := deploy:package($collection, $expathConf)
    let $null := (
        repo:remove($expathConf/@name),
        repo:install-and-deploy-from-db($pkg)
    )
    return
        ()
};

declare function deploy:validate() {
    let $uri := request:get-parameter("uri", ())
    return
        if ($uri = repo:list()) then
            map {
                "error": "An app with this URI does already exist",
                "param": "uri"
            }
        else
            let $abbrev := request:get-parameter("abbrev", ())
            return
                if (collection(repo:get-root() || "/" || $abbrev)/*) then
                    map {
                        "error": "There is already an app using this abbreviation",
                        "param": "abbrev"
                    }
                else
                    ()
};

let $abbrev := request:get-parameter("abbrev", ())
let $collection := request:get-parameter("collection", ())
let $errors := deploy:validate()
return
    if (empty($abbrev)) then
        ()
    else if (exists($errors)) then
        $errors
    else
        let $target :=
            if ($collection) then
                $collection
            else
                repo:get-root() || $abbrev
        let $expathConf := if ($target) then xmldb:xcollection($target)/expath:package else ()
        return
        (:    try {:)
                let $target := deploy:create-app($target, $abbrev, $expathConf)
                return
                    map {
                        "target": $target,
                        "abbrev": $abbrev
                    }
        (:    } catch exerr:EXXQDY0003 {:)
        (:        response:set-status-code(403),:)
        (:        <span>You don't have permissions to access or write the application archive.:)
        (:            Please correct the location or log in as a different user.</span>:)
        (:    } catch exerr:EXREPOINSTALL001 {:)
        (:        response:set-status-code(404),:)
        (:        <p>Failed to install application.</p>:)
        (:    }:)
