<#
THIS IS A COMPLETE SAMPLE AND NOT INTENDED FOR PRODUCTION USE.

DO NOT USE THIS CODE, IT HAS BUGS AND IS NOT TESTED BEYOND VERY TARGETTED SCENARIOS.

SUPPORT IS NOT PROVIDED, NOT IMPLIED, NOR WILL BE GIVEN FOR THIS CODE.
#>

<#
    You must have the following environment variables set in your shell before running this script:
    USER_EMAIL          # For User-Agent header to identify you to SEC EDGAR

    AZURE_TENANT_ID     # For auth using the App Registration for managing the Connector in Graph API
    AZURE_CLIENT_ID     # For auth using the App Registration for managing the Connector in Graph API
    AZURE_CLIENT_SECRET # For auth using the App Registration for managing the Connector in Graph API
#>

$ProcessingPath = $PSScriptRoot

$tickerStrings='AAPL,AMD,AMZN,META,GOOG,IBM,INTC,MSFT,NVDA,ORCL,TSLA,V,PNC,JPM,BAC,WFC,USB,COF,TFC,CFG,RF,KEY,MTB,FITB,MA'.Split(',')
$DesiredForms = @('10-K','10-Q','8-K','DEF 14A','DEFA14A')

$USER_AGENT = "SEC-EDGAR-API-Client/1.0 (${env:USER_EMAIL})"
# Load environment variables for auth using the App Registration for managing the Connector in Graph API
$tokenparams = @{
    TenantId = $env:AZURE_TENANT_ID
    ClientId = $env:AZURE_CLIENT_ID
    ClientSecret = ConvertTo-SecureString -String $env:AZURE_CLIENT_SECRET -AsPlainText -Force
    ErrorAction = 'Stop'
}
Push-Location -Path $ProcessingPath

$tickers_response = Invoke-WebRequest https://www.sec.gov/files/company_tickers.json -UserAgent $USER_AGENT
$tickers = [Text.Json.JsonDocument]::Parse($tickers_response.Content).RootElement.EnumerateObject().ForEach({[PSCustomObject]@{Ticker=$_.Value.GetProperty('ticker').GetString();CIK=$_.Value.GetProperty('cik_str').GetInt32().ToString('D10')}})
$CIKs = $tickers.Where({$_.Ticker -in $tickerStrings}).ForEach({[int]$_.CIK})

function ConvertTo-EDGARItem {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]
        $Filings,

        [Parameter(Mandatory)]
        [long]
        $CIK
    )
    for ($i = 0; $i -lt $Filings.accessionNumber.Count; $i++) {
        $accessionNumber = $Filings.accessionNumber[$i]
        $uri = "https://www.sec.gov/Archives/edgar/data/$($CIK.ToString('D10'))/$($accessionNumber.Replace('-',''))/${accessionNumber}.txt"
        [PSCustomObject][ordered]@{
            CIK = $CIK
            Uri = $uri
            AccessionNumber = $accessionNumber
            FileName = $uri.Substring($uri.LastIndexOf('/') + 1)
            OutFile = './' + $uri.Substring($uri.IndexOf('www.sec.gov'))
            FilingDate = $Filings.filingDate[$i]
            ReportDate = $Filings.reportDate[$i]
            AcceptanceDateTime = $Filings.acceptanceDateTime[$i]
            Act = $Filings.act[$i]
            Form = $Filings.form[$i]
            FileNumber = $Filings.fileNumber[$i]
            FilmNumber = $Filings.filmNumber[$i]
            Items = $Filings.items[$i]
            Core_type = $Filings.core_type[$i]
            Size = $Filings.size[$i]
            IsXBRL = $Filings.isXBRL[$i]
            IsInlineXBRL = $Filings.isInlineXBRL[$i]
            PrimaryDocument = $Filings.primaryDocument[$i]
            PrimaryDocDescription = $Filings.primaryDocDescription[$i]
        }
    }
}

$allFilings = [Collections.Generic.List[PSCustomObject]]@()
$companyInfo = [Collections.Generic.List[PSCustomObject]]@()
foreach ($CIK in $CIKs) {
    Write-Host "Fetching submissions for CIK: $CIK"
    $submissions = Invoke-RestMethod -Uri "https://data.sec.gov/submissions/CIK$($CIK.ToString('D10')).json" -UserAgent $USER_AGENT
    $companyInfo.Add($submissions)
    $submissions.filings.recent | ConvertTo-EDGARItem -CIK $CIK | ForEach-Object {
        $allFilings.Add($_)
    }
    foreach ($file in $submissions.filings.files) {
        $archiveSubmissions = Invoke-RestMethod -Uri "https://data.sec.gov/submissions/$($file.name)" -UserAgent $USER_AGENT
        $archiveSubmissions | ConvertTo-EDGARItem -CIK $CIK | ForEach-Object {
            $allFilings.Add($_)
        }
    }
}
$sortedFilings = $allFilings | Where-Object { -not (Test-Path -Path $_.OutFile)} | Sort-Object -Descending -Property AcceptanceDateTime,Uri

$i=1
$req=0
$sw = [Diagnostics.Stopwatch]::StartNew()
foreach ($filing in $sortedFilings) {
    if (-not (Test-Path -Path $filing.OutFile)) {
        if (-not (Test-Path -Path (Split-Path -Path $filing.OutFile -Parent))) {
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $filing.OutFile -Parent) -Force
        }
        Write-Host "Downloading: $($filing.FileName) ($i/$($sortedFilings.Count))"
        while ($true) {
            try {
                $req++
                $null = Invoke-WebRequest -Uri $filing.Uri -OutFile $filing.OutFile -UserAgent $USER_AGENT -ErrorAction Stop
                if (($req % 100) -eq 0 -or $sw.Elapsed.TotalSeconds -ge 60) {
                    $sw.Stop()
                    Write-Host "Requests: $req, Time: $($sw.Elapsed.TotalSeconds) seconds, Average: $([Math]::Round($req/$sw.Elapsed.TotalSeconds, 2)) request/second"
                    $req = 0
                    $sw.Restart()
                }
                break
            }
            catch {
                Write-Warning "Failed to download $($filing.FileName): $($_.Exception.Message)"
                Start-Sleep -Seconds 5
            }
        }
    } else {
        Write-Host "Already downloaded: $($filing.FileName) ($i/$($sortedFilings.Count))"
    }
    $i++
}


$forms = $allFilings.Where({$_.Form -in $DesiredForms})
$def = $forms | Sort-Object AcceptanceDateTime, Uri -Descending

$headers = [Regex]::new('(?<=^\n*)(?<headers>(.|\n)+?)(?=\n<DOCUMENT>)',[Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$document = [Regex]::new('(?<=^|\r?\n)<DOCUMENT>\r?\n?(?<content>(.|\r?\n)*?)\n?</DOCUMENT>(?=\r?\n|$)',[Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$text = [Regex]::new('(?<=^|\r?\n)<TEXT>\r?\n?(?<content>(.|\n)*?)\r?\n?</TEXT>(?=\r?\n|$)',[Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$pdf = [Regex]::new('(?<=^|\r?\n)<PDF>\r?\n?(?<content>(.|\n)*?)\r?\n?</PDF>(?=\r?\n|$)',[Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$xbrl = [Regex]::new('(?<=^|\r?\n)<XBRL>\r?\n?(?<content>(.|\n)*?)\r?\n?</XBRL>(?=\r?\n|$)',[Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$xml = [Regex]::new('(?<=^|\r?\n)<XML>\r?\n?(?<content>(.|\n)*?)\r?\n?</XML>(?=\r?\n|$)',[Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$html = [Regex]::new('(?<=^|\r?\n)<html[^>]*?>\r?\n?(?<content>(.|\n)*?)\r?\n?</html>(?=\r?\n|$)',[Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$uuencode = [Regex]::new('(?<=^|\r?\n)begin (?<permissions>[0-7]{3}) (?<filename>\S+)\n(.|\n)*?\r?\nend(?=\r?\n|$)',[Text.RegularExpressions.RegexOptions]'ExplicitCapture,Compiled')

$whitespaceAfterTagPattern = [regex]::new('(?<=</[^>]+?>|<[^>]+?/>)\s+', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$whitespaceBetweenTagsPattern = [regex]::new('(?<=<[^>]+?>)\s+?(?=<[^>]+?>)', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$extraAttributesPattern = [regex]::new('(?<=</?[\w:-]+) (?<!<(a|img) )[^>]+?(?=/?\s*>)', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$selfClosingTagPattern = [regex]::new('<(?!/)(?<tag>[^>]+?\b)\s*/\s*>', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$paragraphTagPattern = [regex]::new('<(p|br|div)>', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$aTagPattern = [regex]::new('<a [^>]*?href\s*=\s*(?<quote>["''])(?<target>((?!\k<quote>).)+?)\k<quote>[^>]*?>(?<display>(.|\n)+?)</a>', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')

# $tagPattern = [regex]::new('<(?<tag>\w[\w:-]+) *(?<attribs>(?<= +)[^>]*?)/?>((?<content>(.|\n)*?)</\k<tag>>)?', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')

$imgTagPattern = [regex]::new('<img (?<attribs>[^>]*?)/?>((?<text>(.|\n)*?)</img>)?', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
# $unsupportedTagPattern = [regex]::new('<(?!/?(\w[\w-]*\w:\w[\w-]*\w?|table|t[rhd]|[ou]l|li|b|strong|u|i|em|h[1-6]|su[pb]|hr)\b/?>|/?(a|img) [^>]+?>)[^>]+?>', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')

$attributePattern = [regex]::new('(?<name>\w[\w-]*)(\s*=\s*(?<q>["''])(?<value>(?:(?!\k<q>).)+?)\k<q>)?', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')

$formatTagPattern = [regex]::new('<(?<tag>i|em|b|strong)>(?<content>(.|\n)*?)</\k<tag>>', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$headerTagPattern = [regex]::new('<(?<tag>h[1-6])>', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$listItemTagPattern = [regex]::new('<(?<tag>li)>', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$horizontalRuleTagPattern = [regex]::new('<(?<tag>hr)>', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$unsupportedTagPattern = [regex]::new('<(?!/?(\w[\w-]*\w:\w[\w-]*\w?|table|t[rhd]|u|su[pb])\b/?>|/?(a|img) [^>]+?>)[^>]+?>', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')

$ixHeaderPattern = [regex]::new('<ix:header>(.|\n)*?</ix:header>', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$ixTagPattern = [regex]::new('</?ix:\w+?>', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')

# $tagPattern = [regex]::new('<(?<name>\w+)\b[^>]*>(?<content>(?:[^<]+|<(?!/?\k<name>\b)[^>]*>|<\k<name>\b[^>]*>(?<DEPTH>)|</\k<name>>(?<-DEPTH>))*(?(DEPTH)(?!)))</\k<name>>',[Text.RegularExpressions.RegexOptions]'ExplicitCapture,IgnoreCase,Compiled')
$emptyTagPattern = [regex]::new('<(?<name>\w+)\b[^>]*>(?<content>(?:(\s|\n)*|<(?!/?\k<name>\b)[^>]*>|<\k<name>\b[^>]*>(?<DEPTH>)|</\k<name>>(?<-DEPTH>))*(?(DEPTH)(?!)))</\k<name>>',[Text.RegularExpressions.RegexOptions]'ExplicitCapture,IgnoreCase,Compiled')
$emptyTableRowPattern = [regex]::new('<(?<name>tr)\b[^>]*>(?<content>(?:(</?t[hd]>|\s|\n)*|<(?!/?\k<name>\b)[^>]*>|<\k<name>\b[^>]*>(?<DEPTH>)|</\k<name>>(?<-DEPTH>))*(?(DEPTH)(?!)))</\k<name>>',[Text.RegularExpressions.RegexOptions]'ExplicitCapture,IgnoreCase,Compiled')
$emptyTablePattern = [regex]::new('<(?<name>table)\b[^>]*>(?<content>(?:(\s|\n)*|<(?!/?\k<name>\b)[^>]*>|<\k<name>\b[^>]*>(?<DEPTH>)|</\k<name>>(?<-DEPTH>))*(?(DEPTH)(?!)))</\k<name>>',[Text.RegularExpressions.RegexOptions]'ExplicitCapture,IgnoreCase,Compiled')


# $emptyTagPattern = [regex]::new('<(?!t[hd])(?<tag>[^>]+?)>( |\n)*?</\k<tag>>', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
# $emptyTableRowPattern = [regex]::new('\n?<tr>(</?t[hd]>|\s|\n)*?</tr>', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
# $emptyTablePattern = [regex]::new('<table>(\s|\n)*?</table>', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')

$tableRowLineBreakPattern = [regex]::new('(?<!\n)(?=<(/?(table|tr)|t[hd])>)|(?<=<(/?(table|tr)|/t[hd])>)(?!\n)', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')

$spaceInsideTagPattern = [regex]::new('(?<=<(?!/)[^>]+?>)((?!\n)\s)+|((?!\n)\s)+(?=</[^>]+?>)', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$single_line_tables_pattern = [regex]::new('((?<=\n) +)?<table>( |\n)*<tr>(?<row>((?!<tr>).|\n)*?)</tr>( |\n)*</table> *(\n(?! *<hr>))?', [Text.RegularExpressions.RegexOptions]'IgnoreCase,Compiled,ExplicitCapture')
$cell_value_pattern = [regex]::new('<td>(?<value>.*?)</td>', [Text.RegularExpressions.RegexOptions]'IgnoreCase,Compiled,ExplicitCapture')
$normalizeWhitespacePattern = [regex]::new('(?!\n)\s', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$trailingWhitespacePattern = [regex]::new(' +(?=\n|$)', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$leadingWhitespacePattern = [regex]::new('(?<=\n|^) +(?=<)', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')
$multipleNewlinesPattern = [regex]::new('(?<=([^\n]|^)\n{2})\n+', [Text.RegularExpressions.RegexOptions]'IgnoreCase,ExplicitCapture,Compiled')

$CleanupPipeline = [Func[string, string][]]@(
    {$args[0].Replace("`r`n", "`n")},
    {$args[0].Replace("`r", "`n")},
    {$args[0].Replace("`n", ' ')},
    {$whitespaceAfterTagPattern.Replace($args[0],[string]::Empty)}
    {$whitespaceBetweenTagsPattern.Replace($args[0],[string]::Empty)}
    {$extraAttributesPattern.Replace($args[0],[string]::Empty)}
    {$selfClosingTagPattern.Replace($args[0],'<${tag}></${tag}>')}
    {$paragraphTagPattern.Replace($args[0],"`n")}
    {$aTagPattern.Replace($args[0],'[${display}](${target})')}
    {$imgTagPattern.Replace($args[0],[Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $attribs = @{}
        $attributePattern.Matches($m.Groups['attribs'].Value) | ForEach-Object {
            if ($_.Groups['name'].Success) {
                $name = $_.Groups['name'].Value
                $value = if ($_.Groups['value'].Success) { $_.Groups['value'].Value.Trim('"','''') } else { $true }
                $attribs[$name] = $value
            }
        }
        if ($attribs['src']) {
            return "`n![$($attribs['alt'])]($($attribs['src']))`n"
        }
        return ''
    })}
    {$formatTagPattern.Replace($args[0],[Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $wrapper = switch ($m.Groups['tag'].Value.ToLower()) {
            'i' { '_'; break }
            'em' { '_'; break }
            'b' { '*'; break }
            'strong' { '*'; break }
        }
        return "${wrapper}$($m.Groups['content'].Value.Trim())${wrapper}"
    })}
    {$headerTagPattern.Replace($args[0],[Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $level = $m.Groups['tag'].Value.Substring(1,1)
        return "`n" + ('#' * [int]$level) + ' '
    })}
    {$listItemTagPattern.Replace($args[0],"`n- ")}
    {$horizontalRuleTagPattern.Replace($args[0],"`n---`n")}
    {$unsupportedTagPattern.Replace($args[0],[string]::Empty)}
    {$ixHeaderPattern.Replace($args[0],[string]::Empty)}
    {$ixTagPattern.Replace($args[0],[string]::Empty)}
    {$emptyTagPattern.Replace($args[0],[string]::Empty)}
    {$emptyTableRowPattern.Replace($args[0],[string]::Empty)}
    {$emptyTablePattern.Replace($args[0],[string]::Empty)}
    # {$spaceInsideTagPattern.Replace($args[0],[string]::Empty)}
    {[Net.WebUtility]::HtmlDecode($args[0])}
    # {$normalizeWhitespacePattern.Replace($args[0],' ')}
    # {$tableRowLineBreakPattern.Replace($args[0],"`n")}
    # {$single_line_tables_pattern.Replace($args[0], [Text.RegularExpressions.MatchEvaluator] {
    #     param($m)
    #     return [string]::Join('', $cell_value_pattern.Matches($m.Groups['row'].Value).ForEach({ $_.Groups['value'].Value }))
    # })}
    # {$tableRowLineBreakPattern.Replace($args[0],"`n")}
    # {$trailingWhitespacePattern.Replace($args[0],[string]::Empty)}
    # {$leadingWhitespacePattern.Replace($args[0],[string]::Empty)}
    # {$multipleNewlinesPattern.Replace($args[0],[string]::Empty)}
    # {$args[0].Replace(''’', '''')}
    # {$args[0].Replace('“', '"').Replace('”', '"')}
    # {$args[0].Trim()}
)

$Combiner = [Func[Func[string, string], Func[string, string], Func[string, string]]]{
    param(
        [Func[string, string]]$first,
        [Func[string, string]]$second
    )
    if ($null -eq $first -or $null -eq $second) {
        throw "Both functions must be non-null."
    }
    return [Func[string, string]]({return $second.Invoke($first.Invoke($args[0]))}.GetNewClosure())
}
$CleanupDelegate = $CleanupPipeline[0]
for ($i = 1; $i -lt $CleanupPipeline.Count; $i++) {
    $CleanupDelegate = $Combiner.Invoke($CleanupDelegate, $CleanupPipeline[$i])
}

$payloads = [Collections.Generic.List[PSObject]]@()
$extensions = [Collections.Generic.HashSet[string]]@()
for ($f = 0; $f -lt $def.Count; $f++) {
    $content = Get-Content $def[$f].OutFile -Raw
    $fileheaders = $headers.Match($content)
    $header_string = ''
    if ($fileheaders.Success) {
        $header_string = $fileheaders.Groups['headers'].Value
    } else {
        Write-Host "No headers found in $($def[$f].AccessionNumber) - $($def[$f].Form):`n`n$($content.Substring(0,100))`n`n" -ForegroundColor Yellow
    }
    $docs = $document.Matches($content)
    $companyName = $def[$f].CIK
    $ticker = $tickers.Where({[int64]$_.CIK -eq $def[$f].CIK},'first',1)[0].Ticker
    if ($docs.Count -gt 0) {
        $companyName = $header_string.Split("`n").Where({$_.Trim().StartsWith('COMPANY CONFORMED NAME:',[StringComparison]::OrdinalIgnoreCase)},'First',1)[0]
        if ($companyName) {
            $companyName = $companyName.Split(':',2,[StringSplitOptions]::TrimEntries)[1]
        } else {
            # $companyName = $def[$f].CIK
            # $companyName = $header_string.Split("`n").Where({$_.Trim().StartsWith('COMPANY',[StringComparison]::OrdinalIgnoreCase)},'First',1)[0]
            Write-Host "No COMPANY CONFORMED NAME found in header for $($def[$f].AccessionNumber) - $($def[$f].Form). Found:`n${header_string}" -ForegroundColor Yellow
            # $companyName = $companyName.Split(':',2,[StringSplitOptions]::TrimEntries)[1]
        }
    }
    for ($i = 0; $i -lt $docs.Count; $i++) {
        $doc = $docs[$i].Groups['content'].Value
        $docparts = $text.Match($doc)
        if (!$docparts.Success) {
            Write-Warning "No text found in document $($i + 1) of $($def[$f].AccessionNumber) - $($def[$f].Form)"
            continue
        }
        $doc_headers = $doc.Substring(0,$docparts.Index).Trim()
        $filename = $doc_headers.Split("`n").Where({$_.Trim().StartsWith('<FILENAME>',[StringComparison]::OrdinalIgnoreCase)},'First',1)[0]
        if ($filename) {
            $filename = $filename.Split('>',2,[StringSplitOptions]::TrimEntries)[1]
            $extension = [IO.Path]::GetExtension($filename)
            $null = $extensions.Add($extension)
            if ($extension -notin @('.htm','.txt')) {
                # Write-Host "$($def[$f].AccessionNumber) - $($def[$f].Form) - Document index $($i + 1) - Skipping unwanted document with extension $extension" -ForegroundColor Yellow
                continue
            }
        }
        $sequence = $null
        try {
            $sequence = [int]$doc_headers.Split("`n").Where({$_.Trim().StartsWith('<SEQUENCE>',[StringComparison]::OrdinalIgnoreCase)},'First',1)[0].Split('>',2,[StringSplitOptions]::TrimEntries)[1]
        } catch {
            Write-Warning "Unable to find <SEQUENCE> in document $($i + 1) of $($def[$f].AccessionNumber) - $($def[$f].Form)"
            continue
        }
        $description = $doc_headers.Split("`n").Where({$_.Trim().StartsWith('<DESCRIPTION>',[StringComparison]::OrdinalIgnoreCase)},'First',1)[0]
        if ($description) { 
            $description = $description.Split('>',2,[StringSplitOptions]::TrimEntries)[1]
        }

        $htmlBody = ($docparts.Groups['content'].Value -split '</?body[^>]*?>',3)[1]
        if (![string]::IsNullOrEmpty($html) -and ($xbrlmatch=$xbrl.Match($docparts.Groups['content'].Value)).Success) {
            $htmlBody = [Net.WebUtility]::HtmlDecode($xbrlmatch.Groups['content'].Value)
        }
        elseif(![string]::IsNullOrEmpty($html) -and ($xmlmatch=$xml.Match($docparts.Groups['content'].Value)).Success) {
            $htmlBody = [Net.WebUtility]::HtmlDecode($xmlmatch.Groups['content'].Value)
        }
        if ([string]::IsNullOrEmpty($htmlBody)) {
            if (!$docparts.Success) {
                $type = 'Raw'
                Write-Host "$($def[$f].AccessionNumber) - $($def[$f].Form) - Document index $($i + 1) - $type" -ForegroundColor Yellow
                $parsedContent = $doc
            } else {
                if (($pdfmatch=$pdf.Match($docparts.Groups['content'].Value)).Success) {
                    $type = 'PDF'
                    Write-Host "$($def[$f].AccessionNumber) - $($def[$f].Form) - Document index $($i + 1) - $type" -ForegroundColor Yellow
                    # Skip Binary Documents
                    continue
                    $parsedContent = $docparts.Groups['content'].Value
                }
                elseif(($uuencodematch=$uuencode.Match($docparts.Groups['content'].Value)).Success) {
                    $type = 'Binary'
                    Write-Host "$($def[$f].AccessionNumber) - $($def[$f].Form) - Document index $($i + 1) - $type" -ForegroundColor Yellow
                    # Skip Binary Documents
                    continue
                    $parsedContent = $docparts.Groups['content'].Value
                }
                else {
                    # $firstLine = ($docparts.Groups['content'].Value.TrimStart() -split '\r?\n', 2)[0].Trim()
                    $type = 'Text'
                    # if ($extension -in @('.js','.json','.css')) {
                    #     Write-Host "$($def[$f].AccessionNumber) - $($def[$f].Form) - Document index $($i + 1) - ${type} is $extension, skipping..." -ForegroundColor Yellow
                    #     continue
                    # }
                    $parsedContent = $docparts.Groups['content'].Value
                    Write-Host "$($def[$f].AccessionNumber) - $($def[$f].Form) - Document index $($i + 1) - ${type}:`n$doc_headers" -ForegroundColor Green
                }
            }
        }
        else {
            if ($xbrlmatch.Success) {
                $type = 'XBRL'
            }
            elseif ($xmlmatch.Success) {
                $type = 'XML'
            }
            else {
                $type = 'Html'
            }
            Write-Host "$($def[$f].AccessionNumber) - $($def[$f].Form) - Document index $($i + 1) - $type" -ForegroundColor Green

            $parsedContent = $CleanupDelegate.Invoke($htmlBody)
        }
        # $parsedContent = [Web.HttpUtility]::HtmlDecode($parsedContent)

        if ($filename) {
            $URLBase = ($def[$f].Uri.Split('/') | Select-Object -SkipLast 1) -Join '/'
            $URL = "$URLBase/$filename"
        } else {
            $URL = $def[$f].Uri.Replace('.txt','-index.htm')
        }
        $Title = '{0} - {1} - {2}' -f $companyName, $def[$f].Form, $def[$f].FilingDate
        if ($description) {
            $Title = '{0} - {1}' -f $Title, $description
        }
        $Payload = [PSCustomObject][ordered]@{
            acl = @(
                [PSCustomObject][ordered]@{
                    type = 'everyone'
                    accessType = 'grant'
                    value = '6b7ec9ed-eb4a-41dd-818b-f56fb3ab4c47'
                }
            )
            id = '{0}_{1}' -f $def[$f].AccessionNumber, $sequence
            properties = [PSCustomObject][ordered]@{
                Title = $Title
                Description = $def[$f].Description
                Company = $companyName
                Ticker = $ticker
                CIK = $def[$f].CIK
                AccessionNumber = $def[$f].AccessionNumber
                # Url = $def[$f].Uri.Replace('.txt','-index.htm')
                Url = $URL
                Form = $def[$f].Form
                Act = $def[$f].Act
                FilingDate = [DateTime]::ParseExact($def[$f].FilingDate,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
                FileNumber = $def[$f].FileNumber
                FilmNumber = $def[$f].FilmNumber
                Type = $type
                Sequence = [int]$sequence
                Page = -1
                graphId = ''
            }
            content = [PSCustomObject][ordered]@{
                type = 'Text'
                value = $parsedContent
            }
        }
        $Payloads.Add($Payload)
    }
}


$ids = [Collections.Generic.HashSet[string]][string[]]@(Get-Content ./processed_ids.txt -ErrorAction SilentlyContinue)
$docs = [Collections.Generic.HashSet[string]]@()
$ans = [Collections.Generic.HashSet[string]]@()
$uploadsw = [Diagnostics.Stopwatch]::new()
$requests = 0
$batch = [Collections.Generic.List[PSObject]]::new(20)
$payloads | ForEach-Object {
    $payload = $_
    if($ans.Add($payload.properties.AccessionNumber)) {
        Write-Host "Processing new Accession Number: $($payload.properties.AccessionNumber)" -ForegroundColor Cyan
    }
    $null = $docs.Add($payload.id)
    if ($ids.Contains($payload.id)) {
        Write-Host "Skipping already processed payload with ID $($payload.id)" -ForegroundColor Gray
        return
    }
    if ($payload.properties.Sequence -ne 1) {
        $null = $ids.Add($payload.id)
        $payload.id | Add-Content -Path ./processed_ids.txt
        Write-Host "Skipping non-first sequence payload with ID $($payload.id)" -ForegroundColor Gray
        return
    }
    $i = 1
    if ($payload.Properties.Type -eq 'Text') {
        $pattern = $sgml_pattern
    }
    else {
        $pattern = Get-PagePattern $payload.content.value
    }
    $pages = $pattern.Split($payload.content.value)
    # if ($pages.Count -eq 1 -and $pages[0].Length -gt 15000) {
    #     Write-Host "No pages found for $($payload.id). Length: $($payload.content.value.Length)" -ForegroundColor Yellow
    # }
    $batch.Clear()
    foreach ($page in $pages) {
        $pagePayload = $payload | Select-Object -Property *
        $pagePayload.acl = @($payload.acl | ForEach-Object { $_ | Select-Object -Property * })
        $pagePayload.properties = $payload.properties | Select-Object -Property * -ExcludeProperty Type
        $pagePayload.properties.Page = $i
        $pagePayload.content = $payload.content | Select-Object -Property *
        $pagePayload.content.value = $page.TrimEnd()
        $pagePayload.id = '{0}_{1}' -f $payload.id, $i
        if ($ids.Contains($pagePayload.id)) {
            Write-Host "Skipping already processed payload page with ID $($pagePayload.id)" -ForegroundColor Gray
            return
        }
        $pagePayload.properties.graphId = $pagePayload.id
        $pagePayload.properties.Title = '{0} - Page {1}' -f $payload.properties.Title, $i
        $i++
        if ([string]::IsNullOrWhiteSpace($pagePayload.content.value)) {
            Write-Warning "Page $($i-1) of $($payload.id) is empty or whitespace, skipping..."
            continue
        }

        $batch.Add($pagePayload)
        if ($batch.Count -eq 20) {
            $str = @{requests=@($batch | ForEach-Object { @{
                id = $batch.IndexOf($_)
                method = 'PUT'
                url = "/external/connections/SECEDGAR1/items/$($_.id)"
                body = $_
                headers = @{ 'Content-Type' = 'application/json' }
            } })} | ConvertTo-Json -Depth 99 -Compress
            $Retries = 5
            while ($true) {
                try {
                    $uploadsw.Start()
                    $token = (Get-MsalToken @tokenparams)
                    $null = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/$batch' -Method Post -Headers @{Authorization = $token.CreateAuthorizationHeader()} -Body $str -ContentType 'application/json' -ErrorAction Stop
                    $requests += $batch.Count
                    foreach ($pagePayload in $batch) {
                        $null = $ids.Add($pagePayload.id)
                        $pagePayload.id | Add-Content -Path ./processed_ids.txt
                        if (($ids.Count % 100) -eq 0) {
                           Write-Host "Uploaded $($ids.Count) pages in $($docs.Count) documents over $($ans.Count) filings so far. $(($requests/$uploadsw.Elapsed.TotalSeconds).ToString('F2')) r/s on average."
                        }
                    }
                    break
                }
                catch {
                    $Retries--
                    if ($Retries -le 0) {
                        Write-Error "Failed to upload page $($i-1) of $($payload.id) after multiple attempts: $_"
                        break
                    }
                }
                finally {
                    $uploadsw.Stop()
                }
            }
            $batch.Clear()
        }
    }
    if ($batch.Count -gt 0) {
            $str = @{requests=@($batch | ForEach-Object { @{
                id = $batch.IndexOf($_)
                method = 'PUT'
                url = "/external/connections/SECEDGAR1/items/$($_.id)"
                body = $_
                headers = @{ 'Content-Type' = 'application/json' }
            } })} | ConvertTo-Json -Depth 99 -Compress
        $Retries = 5
        while ($true) {
            try {
                $uploadsw.Start()
                $token = (Get-MsalToken @tokenparams)
                $null = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/$batch' -Method Post -Headers @{Authorization = $token.CreateAuthorizationHeader()} -Body $str -ContentType 'application/json' -ErrorAction Stop
                $requests += $batch.Count
                foreach ($pagePayload in $batch) {
                    $null = $ids.Add($pagePayload.id)
                    $pagePayload.id | Add-Content -Path ./processed_ids.txt
                    if (($ids.Count % 100) -eq 0) {
                        Write-Host "Uploaded $($ids.Count) pages in $($docs.Count) documents over $($ans.Count) filings so far. $(($requests/$uploadsw.Elapsed.TotalSeconds).ToString('F2')) r/s on average."
                    }
                }
                break
            }
            catch {
                $Retries--
                if ($Retries -le 0) {
                    Write-Error "Failed to upload page $($i-1) of $($payload.id) after multiple attempts: $_"
                    break
                }
            }
            finally {
                $uploadsw.Stop()
            }
        }
        $batch.Clear()
    }
    $payload.id | Add-Content -Path ./processed_ids.txt
}