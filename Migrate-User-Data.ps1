#Requires -Version 7.0
$ErrorActionPreference = "Continue";

## Variable that contains the root directory of user home folders. Subfolders should match the users SAMAccountName.
[String]$homeRoot = "\\domain\dfsroot\Home";

## logging function.
function Write-Log([String]$msg) {
    [String]$outString =  (Get-Date -Format "MM/dd/yy HH:mm:ss") + ": $msg";
    $outString | Out-File -FilePath ($env:appdata+"\Migrate-User-Data.log") -Append;
} 

## Class used to create objects representing computers that have been processed.
Class Computer {
    [String]$name; 
    [String]$status;

    ## Default constructor 
    Computer () { 
        $this.name = "";
        $this.status = "";
    }
    ## Overloaded constructor
    Computer($name,$status) { 
        $this.name = $name; 
        $this.status = $status;
    } 
    ## Overloaded ToString() method.
    [String] ToString() {
        [String]$outString = "Computer name: " + $this.name + ". Status: " + $this.status + ".";
        return $outString;
    }
}
## Array used to store processed computer objects.
$processedComputers = New-Object System.Collections.ArrayList;

## Stores a list of users to process on remote computers. Only users contained in this variable will have their profiles processed.
$users = (Get-ChildItem -Directory $homeRoot).Name; 

## Stores a list of remote computers to process. Grabs all Windows client machines in the domain.
$computers = (Get-ADComputer -filter * -properties Name,OperatingSystem) | where {($_.OperatingSystem).contains("Windows") -and !($_.OperatingSystem).contains("Server")} | Sort Name; 
$complete = 0;

## Process each computer 1 at a time, alphabetical order.
Write-Log "Information - Begin processing computers.";
$computers | foreach-Object {
    $computer = $_.DNSHostName; 
    Write-Progress -PercentComplete ($complete*100/$computers.count) -Activity "Consolidating profiles from $computer..." -Status 'Processing';
    
    if (Test-Connection -quiet $computer) {
        Write-Log "Information - processing computer $computer.";
        
        ## Stores a list of profile directories on the remote system.
        $profiles = (Get-ChildItem -Directory "\\$computer\C`$\Users\");
        
        ## Process every profile on the remote machine concurrently.
        $profiles | ForEach-Object -Parallel { 
            $prof = $_.Name;
            function Move-UserData([String]$user,[String]$datapath) { 
                $userHome = "$using:homeRoot\$user"; 
                ##Copy Desktop        
                Robocopy.exe "$datapath\Desktop" "$userHome\Desktop" /xf *.lnk /np /nfl /ndl /mt:128 /copyall /e /zb /xo    

                ##Copy Documents 
                Robocopy.exe "$datapath\Documents" "$userHome\Documents" /np /nfl /ndl /mt:128 /copyall /e /zb /xo  
    
                ##Copy Favorites 
                Robocopy.exe "$datapath\Favorites" "$userHome\Favorites" /xf *.lnk /np /nfl /ndl /mt:128 /copyall /e /zb /xo  
    
                ##Copy Pictures
                Robocopy.exe "$datapath\Pictures" "$userHome\Pictures" /np /nfl /ndl /mt:128 /copyall /e /zb /xo   

                ##Copy Music 
                Robocopy.exe "$datapath\Music" "$userHome\Music" /np /nfl /ndl /mt:128 /copyall /e /zb /xo 

                ##Copy Contacts 
                Robocopy.exe "$datapath\Contacts" "$userHome\Contacts" /np /nfl /ndl /mt:128 /copyall /e /zb /xo 
    
                ##Copy Downloads 
                Robocopy.exe "$datapath\Downloads" "$userHome\Downloads" /np /nfl /ndl /mt:128 /copyall /e /zb /xo  

                ##Copy Videos 
                Robocopy.exe "$datapath\Videos" "$userHome\Videos" /np /nfl /ndl /mt:128 /copyall /e /zb /xo                  
    
                ##Copy Chrome Bookmarks
                if(Test-Path "$datapath\AppData\Local\Google\Chrome\User Data\Default\Bookmarks") { 
                    if (Test-Path "$userHome\AppData\Local\Google\Chrome\User Data\Default\Bookmarks") { 
                        ## Stores the existing bookmarks file in the users home directory.
                        $homeBooks = Get-Content "$userHome\AppData\Local\Google\Chrome\User Data\Default\Bookmarks" | ConvertFrom-Json; 
                        
                        ## Stores bookmarks in the profile of the remote system.
                        $localBooks = "$datapath\AppData\Local\Google\Chrome\User Data\Default\Bookmarks" | ConvertFrom-Json;
                        
                        ## Process each bookmark and add it to the redirected location.
                        $hives = (($localBooks.roots | gm -MemberType NoteProperty) | where {$_.Name -ne "synced"}).Name;
                        foreach ($hive in $hives) {
                            foreach ($localBook in $localBooks.roots.$hive.children) { 
                                [Boolean]$exists = $false;
                                foreach ($homeBook in $homeBooks.roots.bookmark_bar.children) { 
                                    if ($homeBook.url -eq $localBook.url) { 
                                        $exists = $true; 
                                    }
                                }
                                foreach ($homeBook in $homeBooks.roots.other.children) { 
                                    if ($homeBook.url -eq $localBook.url) { 
                                        $exists = $true; 
                                    }
                                }
                                if (!$exists) { 
                                    $book = $localBook;
                                    if ($hive -eq "bookmark_bar") { 
                                        $book.id = [String]([Int]($homeBooks.roots.bookmark_bar.children)[($homeBooks.roots.bookmark_bar.children).length - 1].id + 1);
                                        $book.guid = (New-Guid).Guid;
                                        $homeBooks.roots.bookmark_bar.children += $book;
                                    } 
                                    else { 
                                        $book.id = [String]([Int]($homeBooks.roots.other.children)[($homeBooks.roots.other.children).length - 1].id + 1);
                                        $book.guid = (New-Guid).Guid;
                                        $homeBooks.roots.other.children += $book;
                                    }
                                }
                            }                
                        }  
                        $homeBooks | Out-File "$userHome\AppData\Local\Google\Chrome\User Data\Default\Bookmarks" -force;
                    }
                    else { 
                        Robocopy.exe "$datapath\AppData\Local\Google\Chrome\User Data\Default" "$userHome\AppData\Local\Google\Chrome\User Data\Default" Bookmarks  /np /nfl /ndl /mt:128 /copyall /zb 
                    } 
                }
        }  
            if (($using:users) -contains $prof) {  
                $datapath = "\\$using:computer\C`$\Users\$profile";
                Move-UserData $profile $datapath;
            }  
        } -ThrottleLimit 10 -AsJob;
        Write-Log ("Information - finished processing $computer.");
        $processedComputers.Add((New-Object Computer($computer,"Success"))); 
    }  
    else { 
        Write-Log "Information - unable to connect to $computer."; 
        $processedComputers.Add((New-Object Computer($computer,"Failure"))); 
    }
    $complete++;
}; 
Write-Log "Information - Finished processing computers."; 
$processedComputers | Export-Csv -Path ($env:appdata+"\Migrate-User-Data.log");