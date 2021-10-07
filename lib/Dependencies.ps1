'core', 'Helpers', 'install', 'decompress', 'Versions' | ForEach-Object {
    . (Join-Path $PSScriptRoot "$_.ps1")
}

# Return array of plain text values to be resolved
function Get-ManifestDependency {
    param($Manifest, $Architecture)

    process {
        $result = @()

        # TODO: Support requirements property
        # Direct dependencies defined in manifest
        if ($Manifest.depends) { $result += $Manifest.depends }

        $pre_install = arch_specific 'pre_install' $Manifest $Architecture
        $installer = arch_specific 'installer' $Manifest $Architecture
        $post_install = arch_specific 'post_install' $Manifest $Architecture

        # Indirect dependencies
        $result += Get-UrlDependency -Manifest $Manifest -Architecture $Architecture
        $result += Get-ScriptDependency -ScriptProperty ($pre_install + $installer.script + $post_install)

        return $result | Select-Object -Unique
    }
}

# TODO: More pretty, better implementation
function Get-ScriptDependency {
    param($ScriptProperty)

    process {
        $dependencies = @()
        $s = $ScriptProperty

        if ($ScriptProperty -is [Array]) { $s = $ScriptProperty -join "`n" }

        # Exit immediatelly if there are no expansion functions
        if ([String]::IsNullOrEmpty($s)) { return $dependencies }
        if ($s -notlike '*Expand-*Archive *') { return $dependencies }

        if (($s -like '*Expand-DarkArchive *') -and !(Test-HelperInstalled -Helper 'Dark')) { $dependencies += 'dark' }
        if (($s -like '*Expand-MsiArchive *') -and !(Test-HelperInstalled -Helper 'Lessmsi')) { $dependencies += 'lessmsi' }

        # 7zip
        if (($s -like '*Expand-7zipArchive *') -and !(Test-HelperInstalled -Helper '7zip')) {
            # Do not add if 7ZIPEXTRACT_USE_EXTERNAL is used
            if (($false -eq (get_config '7ZIPEXTRACT_USE_EXTERNAL' $false))) {
                $dependencies += '7zip'
            }
        }

        # Inno; innoextract or innounp
        if ($s -like '*Expand-InnoArchive *') {
            # Use innoextract
            if ((get_config 'INNOSETUP_USE_INNOEXTRACT' $false) -or ($s -like '* -UseInnoextract*')) {
                if (!(Test-HelperInstalled -Helper 'InnoExtract')) { $dependencies += 'innoextract' }
            } else {
                # Default innounp
                if (!(Test-HelperInstalled -Helper 'Innounp')) { $dependencies += 'innounp' }
            }
        }

        # zstd
        if (($s -like '*Expand-ZstdArchive *') -and !(Test-HelperInstalled -Helper 'Zstd')) {
            # Ugly, unacceptable and horrible patch to cover the tar.zstd use cases
            if (!(Test-HelperInstalled -Helper '7zip')) { $dependencies += '7zip' }
            $dependencies += 'zstd'
        }

        return $dependencies | Select-Object -Unique
    }
}

function Get-UrlDependency {
    param($Manifest, $Architecture)

    process {
        $dependencies = @()
        $urls = url $Manifest $Architecture

        if ((Test-7zipRequirement -URL $urls) -and !(Test-HelperInstalled -Helper '7zip')) { $dependencies += '7zip' }
        if ((Test-LessmsiRequirement -URL $urls) -and !(Test-HelperInstalled -Helper 'Lessmsi')) { $dependencies += 'lessmsi' }

        if ($manifest.innosetup) {
            if (get_config 'INNOSETUP_USE_INNOEXTRACT' $false) {
                if (!(Test-HelperInstalled -Helper 'Innoextract')) { $dependencies += 'innoextract' }
            } else {
                if (!(Test-HelperInstalled -Helper 'Innounp')) { $dependencies += 'innounp' }
            }
        }

        if ((Test-ZstdRequirement -URL $urls) -and !(Test-HelperInstalled -Helper 'Zstd')) {
            # Ugly, unacceptable and horrible patch to cover the tar.zstd use cases
            if (!(Test-HelperInstalled -Helper '7zip')) { $dependencies += '7zip' }
            $dependencies += 'zstd'
        }

        return $dependencies | Select-Object -Unique
    }
}

# Resolve dependencies for provided array of already resolved manifests (Array of `Resolve-ManifestInformation`)
# Recursive dependency support
# Replacement of install_order function
# Returns aray of Resolve-ManifestInformation objects to be installed
#   Including dependencies (first) and final manifests
#   In case of multiple versions of one manifest, the newest one will be handled
function Resolve-InstallationQueueDependency {
    param($ResolvedManifestInformation, $Architecture)

    process {
        $result = @() # All final manifests to install

        foreach ($single in $ResolvedManifestInformation) {
            $dependencies = @()

            try {
                $dependencies = Resolve-AllManifestDependency -ManifestInformation $single -Architecture $Architecture
            } catch {
                Write-UserMessage -Message "Cannot resolve dependency for '$($single.ApplicationName)' ($($_.Exception.Message))" -Err
                continue
            }

            foreach ($dep in $dependencies) {
                # Add dependency if already not added
                if ($result.ApplicationName -contains $dep.ApplicationName) {
                    $cmp = Compare-Version -DifferenceVersion $result.Version -ReferenceVersion $dep.Version
                    if (1 -eq $cmp) {
                        Write-UserMessage -Message "$($dep.ApplicationName) is already added" -Info
                    }
                } else {
                    $dep | Add-Member -MemberType 'NoteProperty' -Name 'Dependency' -Value $true
                    $result += $dep
                }
            }

            # Add the original application
            # TODO: Use case when the application is already there should not happen
            if ($result.ApplicationName -notcontains $single.ApplicationName) {
                $result += $single
            } else {
                Write-UserMessage -Message 'Happened. Please report what manifest you are trying to install to ''https://github.com/Ash258/Scoop-Core/issues/new?title=DependencyResolveItself''' -Err
            }
        }

        return $result
    }
}

# http://www.electricmonk.nl/docs/dependency_resolving_algorithm/dependency_resolving_algorithm.html
function Resolve-AllManifestDependency {
    param($ManifestInformation, $Architecture)

    process {
        $resolved = New-Object System.Collections.ArrayList

        dep_resolve2 $ManifestInformation $Architecture $resolved @()

        if ($resolved.Count -eq 1) { $resolved = New-Object System.Collections.ArrayList } # No dependencies

        return $resolved
    }
}

function dep_resolve2($ManifestInformation, $Architecture, $Resolved, $Unresolved) {
    #[out]$resolved
    #[out]$unresolved

    $Unresolved += $ManifestInformation

    if (!$ManifestInformation.ManifestObject) {
        if ($ManifestInformation.Bucket -and ((Get-LocalBucket) -notcontains $ManifestInformation.Bucket)) {
            Write-UserMessage -Message "Bucket '$($ManifestInformation.Bucket)' not installed. Add it with 'scoop bucket add $($ManifestInformation.Bucket)' or 'scoop bucket add $($ManifestInformation.Bucket) <repo>'." -Warning
        }

        throw [ScoopException] "Could not find manifest for '$($ManifestInformation.OriginalQuery)'" # TerminatingError thrown
    }

    $deps = Get-ManifestDependency $ManifestInformation.ManifestObject $Architecture

    foreach ($dep in $deps) {
        if ($resolved -notcontains $dep) {
            if ($unresolved -contains $dep) {
                throw [ScoopException] "Circular dependency detected: '$app' -> '$dep'." # TerminatingError thrown
            }
            dep_resolve2 $dep $Architecture $Resolved $Unresolved
        }
    }
    $Resolved.Add($ManifestInformation) | Out-Null
    $Unresolved = $Unresolved -ne $app # Remove from unresolved
}
