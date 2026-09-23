@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem ===== BEGIN EDITABLE SETTINGS =====
set "CODEX_LIGHTWEIGHT_BASE_URL=https://ai2.heigh.vip/v1"
set "CODEX_LIGHTWEIGHT_API_KEY=sk-REPLACE_WITH_YOUR_API_KEY"
set "CODEX_LIGHTWEIGHT_DEFAULT_MODEL=gpt-5.6-terra"
set "CODEX_LIGHTWEIGHT_REASONING_EFFORT=xhigh"
rem ===== END EDITABLE SETTINGS =====

set "CODEX_LIGHTWEIGHT_SELF=%~f0"
rem Optional beginner-friendly override: drag a CODEX_HOME folder onto this BAT.
rem It takes precedence over a stale inherited CODEX_HOME value.
if not "%~1"=="" set "CODEX_LIGHTWEIGHT_CODEX_HOME=%~f1"
set "CODEX_LIGHTWEIGHT_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if defined PROCESSOR_ARCHITEW6432 if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "CODEX_LIGHTWEIGHT_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%CODEX_LIGHTWEIGHT_POWERSHELL%" goto :missing_powershell

"%CODEX_LIGHTWEIGHT_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$self=$env:CODEX_LIGHTWEIGHT_SELF; $raw=[IO.File]::ReadAllText($self,[Text.UTF8Encoding]::new($false,$true)); $marker=('# POWERSHELL_PAYLOAD'+'_BEGIN'); $at=$raw.IndexOf($marker,[StringComparison]::Ordinal); if($at -lt 0){throw 'Embedded PowerShell payload was not found.'}; $code=$raw.Substring($at+$marker.Length); & ([ScriptBlock]::Create($code))"
set "CODEX_LIGHTWEIGHT_EXIT=%ERRORLEVEL%"
goto :finished

:missing_powershell
echo [codex-lightweight] ERROR: Windows PowerShell 5.1 was not found.
set "CODEX_LIGHTWEIGHT_EXIT=1"

:finished
echo.
if not "%CODEX_LIGHTWEIGHT_EXIT%"=="0" (
  echo [codex-lightweight] Setup failed. Exit code: %CODEX_LIGHTWEIGHT_EXIT%.
  echo [codex-lightweight] Review the timestamped ERROR/POSITION/ROLLBACK lines above before retrying.
) else (
  echo ================================================================
  echo   IMPORTANT: FULLY RESTART CODEX / CHATGPT AFTER THIS SCRIPT.
  echo ================================================================
)
echo.
if /i not "%CODEX_LIGHTWEIGHT_NO_PAUSE%"=="1" pause
exit /b %CODEX_LIGHTWEIGHT_EXIT%

# POWERSHELL_PAYLOAD_BEGIN
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not [Environment]::Is64BitProcess) {
    [Console]::Error.WriteLine('[codex-lightweight] ERROR: A 64-bit Windows PowerShell process is required.')
    exit 1
}
$windowsSqlite = Join-Path $env:SystemRoot 'System32\winsqlite3.dll'
if (-not (Test-Path -LiteralPath $windowsSqlite -PathType Leaf)) {
    [Console]::Error.WriteLine("[codex-lightweight] ERROR: Required Windows component was not found: $windowsSqlite")
    exit 1
}

$jsonlSource = @'
// Windows-only, dependency-free JSONL migration core for the lightweight Codex setup.
// Designed to compile with Windows PowerShell 5.1 Add-Type (C# 5 syntax).
// This source intentionally does not enumerate CODEX_HOME; orchestration and ledger
// ownership belong to the calling PowerShell script.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace CodexLightweight
{
    public sealed class JsonlMigrationException : Exception
    {
        public JsonlMigrationException(string message) : base(message) { }
        public JsonlMigrationException(string message, Exception inner) : base(message, inner) { }
    }

    public sealed class JsonlMigrationPlan
    {
        private readonly byte[] beforeBytes;
        private readonly byte[] afterBytes;
        private readonly string[] sessionIds;
        private readonly string[] sourceProviders;

        internal JsonlMigrationPlan(
            string filePath,
            long originalLength,
            long originalLastWriteUtcTicks,
            string beforeSha256,
            string afterSha256,
            string nonProviderSha256,
            int lineCount,
            string canonicalSessionId,
            string[] sessionIds,
            string[] sourceProviders,
            int changedMetaLines,
            byte[] beforeBytes,
            byte[] afterBytes)
        {
            this.FilePath = filePath;
            this.OriginalLength = originalLength;
            this.OriginalLastWriteUtcTicks = originalLastWriteUtcTicks;
            this.BeforeSha256 = beforeSha256;
            this.AfterSha256 = afterSha256;
            this.NonProviderSha256 = nonProviderSha256;
            this.LineCount = lineCount;
            this.CanonicalSessionId = canonicalSessionId;
            this.sessionIds = (string[])sessionIds.Clone();
            this.sourceProviders = (string[])sourceProviders.Clone();
            this.ChangedMetaLines = changedMetaLines;
            this.beforeBytes = beforeBytes;
            this.afterBytes = afterBytes;
        }

        public string FilePath { get; private set; }
        public long OriginalLength { get; private set; }
        public long OriginalLastWriteUtcTicks { get; private set; }
        public string BeforeSha256 { get; private set; }
        public string AfterSha256 { get; private set; }
        public string NonProviderSha256 { get; private set; }
        public int LineCount { get; private set; }
        public string CanonicalSessionId { get; private set; }
        public string[] SessionIds { get { return (string[])this.sessionIds.Clone(); } }
        public string[] SourceProviders { get { return (string[])this.sourceProviders.Clone(); } }
        public int ChangedMetaLines { get; private set; }

        internal byte[] BeforeBytes { get { return this.beforeBytes; } }
        internal byte[] AfterBytes { get { return this.afterBytes; } }
    }

    public sealed class JsonlApplyResult
    {
        internal JsonlApplyResult(string filePath, string backupPath, int changedMetaLines)
        {
            this.FilePath = filePath;
            this.BackupPath = backupPath;
            this.ChangedMetaLines = changedMetaLines;
        }

        public string FilePath { get; private set; }
        public string BackupPath { get; private set; }
        public int ChangedMetaLines { get; private set; }
    }

    public static class JsonlMigration
    {
        private const string TargetProvider = "custom";
        private static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false, true);
        private static readonly Regex UuidPattern = new Regex(
            "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
            RegexOptions.Compiled | RegexOptions.CultureInvariant);
        private static readonly string[] SessionIdKeys = new string[] { "id", "session_id", "thread_id" };

        // Returns null when the file is already idempotently unified or contains
        // no matching session metadata.
        public static JsonlMigrationPlan PlanFile(string path)
        {
            string fullPath = RequireExistingFile(path);
            StableRead original = ReadStable(fullPath);
            Analysis before = Analyze(original.Bytes, fullPath, true);
            if (before.ChangedMetaLines == 0)
            {
                return null;
            }

            Analysis after = Analyze(before.OutputBytes, fullPath, false);
            if (after.ChangedMetaLines != 0)
            {
                throw new JsonlMigrationException("JSONL rewrite is not idempotent: " + fullPath);
            }
            RequireSameShape(before, after, fullPath);
            if (!FixedTimeEquals(before.NonProviderSha256, after.NonProviderSha256))
            {
                throw new JsonlMigrationException("Non-provider JSONL bytes would change: " + fullPath);
            }

            return new JsonlMigrationPlan(
                fullPath,
                original.Length,
                original.LastWriteUtcTicks,
                Sha256(original.Bytes),
                Sha256(before.OutputBytes),
                before.NonProviderSha256,
                before.LineCount,
                before.CanonicalSessionId,
                Copy(before.SessionIds),
                Copy(before.SourceProviders),
                before.ChangedMetaLines,
                original.Bytes,
                before.OutputBytes);
        }

        // Creates an immutable backup first, replaces the source atomically in the
        // same directory, and validates the complete provider-only invariant. If
        // post-write validation fails, the source is restored automatically.
        public static JsonlApplyResult ApplyPlan(JsonlMigrationPlan plan, string backupPath)
        {
            if (plan == null)
            {
                throw new ArgumentNullException("plan");
            }
            string sourcePath = Path.GetFullPath(plan.FilePath);
            string fullBackupPath = RequireNewBackupPath(sourcePath, backupPath);
            bool replaced = false;
            string temporaryPath = null;
            string replaceBackupPath = null;

            try
            {
                using (FileStream lockedSource = OpenReadDenyWriters(sourcePath))
                {
                    FileInfo currentInfo = NewFileInfo(sourcePath);
                    if (currentInfo.Length != plan.OriginalLength ||
                        currentInfo.LastWriteTimeUtc.Ticks != plan.OriginalLastWriteUtcTicks)
                    {
                        throw new JsonlMigrationException("File changed concurrently before backup: " + sourcePath);
                    }

                    byte[] currentBytes = ReadAll(lockedSource);
                    if (!FixedTimeEquals(Sha256(currentBytes), plan.BeforeSha256) ||
                        !BytesEqual(currentBytes, plan.BeforeBytes))
                    {
                        throw new JsonlMigrationException("File content changed concurrently before backup: " + sourcePath);
                    }

                    WriteNewBackup(fullBackupPath, currentBytes, plan.BeforeSha256);
                    temporaryPath = WriteReplacementTemp(sourcePath, plan.AfterBytes);

                    // The open handle denies writers. FileShare.Delete permits the
                    // atomic replacement itself while preventing a writer from
                    // opening after the verification above.
                    FileInfo immediatelyBefore = NewFileInfo(sourcePath);
                    if (immediatelyBefore.Length != plan.OriginalLength ||
                        immediatelyBefore.LastWriteTimeUtc.Ticks != plan.OriginalLastWriteUtcTicks)
                    {
                        throw new JsonlMigrationException("File changed concurrently during replacement: " + sourcePath);
                    }
                    replaceBackupPath = CreateReplacementBackupPath(sourcePath);
                    File.Replace(temporaryPath, sourcePath, replaceBackupPath, true);
                    temporaryPath = null;
                    replaced = true;
                }

                VerifyApplied(plan);
                return new JsonlApplyResult(sourcePath, fullBackupPath, plan.ChangedMetaLines);
            }
            catch (Exception applyError)
            {
                if (replaced)
                {
                    try
                    {
                        RestoreBackup(sourcePath, fullBackupPath, plan.AfterSha256, plan.BeforeSha256);
                    }
                    catch (Exception restoreError)
                    {
                        throw new JsonlMigrationException(
                            "JSONL migration failed and automatic rollback also failed for " + sourcePath +
                            ". Migration error: " + applyError.Message +
                            ". Rollback error: " + restoreError.Message,
                            restoreError);
                    }
                }
                JsonlMigrationException known = applyError as JsonlMigrationException;
                if (known != null)
                {
                    throw known;
                }
                throw new JsonlMigrationException("JSONL migration failed for " + sourcePath + ": " + applyError.Message, applyError);
            }
            finally
            {
                DeleteTemporary(temporaryPath);
                DeleteTemporary(replaceBackupPath);
            }
        }

        // Intended for the outer migration ledger when a later artifact fails.
        // Restoration is refused if another process has changed the migrated file.
        public static void RestoreBackup(
            string filePath,
            string backupPath,
            string expectedCurrentSha256,
            string expectedBackupSha256)
        {
            string sourcePath = RequireExistingFile(filePath);
            string fullBackupPath = RequireExistingFile(backupPath);
            if (String.IsNullOrWhiteSpace(expectedCurrentSha256))
            {
                throw new ArgumentException("An expected current SHA-256 is required.", "expectedCurrentSha256");
            }
            if (String.IsNullOrWhiteSpace(expectedBackupSha256))
            {
                throw new ArgumentException("An expected backup SHA-256 is required.", "expectedBackupSha256");
            }
            if (PathsEqual(sourcePath, fullBackupPath))
            {
                throw new JsonlMigrationException("Backup path must differ from source path: " + sourcePath);
            }

            byte[] backupBytes = ReadStable(fullBackupPath).Bytes;
            string backupSha256 = Sha256(backupBytes);
            if (!FixedTimeEquals(backupSha256, expectedBackupSha256))
            {
                throw new JsonlMigrationException("Refusing rollback because the backup hash is invalid: " + fullBackupPath);
            }
            string temporaryPath = null;
            string replaceBackupPath = null;
            try
            {
                using (FileStream lockedSource = OpenReadDenyWriters(sourcePath))
                {
                    string currentSha256 = Sha256(ReadAll(lockedSource));
                    if (!FixedTimeEquals(currentSha256, expectedCurrentSha256))
                    {
                        throw new JsonlMigrationException(
                            "Refusing rollback because the migrated file changed concurrently: " + sourcePath);
                    }
                    temporaryPath = WriteReplacementTemp(sourcePath, backupBytes);
                    replaceBackupPath = CreateReplacementBackupPath(sourcePath);
                    File.Replace(temporaryPath, sourcePath, replaceBackupPath, true);
                    temporaryPath = null;
                }

                StableRead restored = ReadStable(sourcePath);
                if (!FixedTimeEquals(Sha256(restored.Bytes), backupSha256) || !BytesEqual(restored.Bytes, backupBytes))
                {
                    throw new JsonlMigrationException("Backup restoration verification failed: " + sourcePath);
                }
            }
            finally
            {
                DeleteTemporary(temporaryPath);
                DeleteTemporary(replaceBackupPath);
            }
        }

        public static string ComputeFileSha256(string path)
        {
            return Sha256(ReadStable(RequireExistingFile(path)).Bytes);
        }

        private static void VerifyApplied(JsonlMigrationPlan plan)
        {
            StableRead current = ReadStable(plan.FilePath);
            if (!FixedTimeEquals(Sha256(current.Bytes), plan.AfterSha256) ||
                !BytesEqual(current.Bytes, plan.AfterBytes))
            {
                throw new JsonlMigrationException("Atomic replacement bytes do not match the plan: " + plan.FilePath);
            }

            Analysis verified = Analyze(current.Bytes, plan.FilePath, false);
            if (verified.ChangedMetaLines != 0)
            {
                throw new JsonlMigrationException("JSONL did not become idempotently custom: " + plan.FilePath);
            }
            if (verified.LineCount != plan.LineCount ||
                !StringArraysEqual(verified.SessionIds, plan.SessionIds) ||
                !String.Equals(verified.CanonicalSessionId, plan.CanonicalSessionId, StringComparison.Ordinal) ||
                !FixedTimeEquals(verified.NonProviderSha256, plan.NonProviderSha256))
            {
                throw new JsonlMigrationException("JSONL identity or non-provider validation failed: " + plan.FilePath);
            }
        }

        private static Analysis Analyze(byte[] bytes, string path, bool buildOutput)
        {
            string text;
            try
            {
                text = StrictUtf8.GetString(bytes);
            }
            catch (DecoderFallbackException error)
            {
                throw new JsonlMigrationException("Rollout is not strict UTF-8: " + path, error);
            }

            List<JsonLine> lines = SplitPhysicalLines(text);
            List<ParsedLine> parsed = new List<ParsedLine>(lines.Count);
            List<string> sessionIds = new List<string>();
            // UUID text is case-insensitive. Keep the first spelling for the
            // public plan/identity report, but do not treat an upper-case copy
            // of the same UUID as a second embedded session.
            HashSet<string> seenSessionIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            for (int index = 0; index < lines.Count; index++)
            {
                ParsedLine item = ParseLine(lines[index].Body, index == 0, path, index + 1);
                parsed.Add(item);
                if (item.IsSessionMeta && item.SessionId == null)
                {
                    throw new JsonlMigrationException(
                        "session_meta has no usable id/session_id/thread_id at " + path + ":" +
                        (index + 1).ToString(CultureInfo.InvariantCulture));
                }
                if (item.IsSessionMeta && seenSessionIds.Add(item.SessionId))
                {
                    sessionIds.Add(item.SessionId);
                }
            }

            string canonicalSessionId = ResolveCanonicalSessionId(path, sessionIds);
            int changed = 0;
            HashSet<string> providers = new HashSet<string>(StringComparer.Ordinal);
            StringBuilder output = buildOutput ? new StringBuilder(text.Length + 64) : null;
            StringBuilder masked = new StringBuilder(text.Length);

            for (int index = 0; index < lines.Count; index++)
            {
                JsonLine line = lines[index];
                ParsedLine item = parsed[index];
                bool matches = item.IsSessionMeta &&
                    (canonicalSessionId == null ||
                     String.Equals(item.SessionId, canonicalSessionId, StringComparison.OrdinalIgnoreCase));
                string updatedBody = line.Body;

                if (matches)
                {
                    if (!item.ProviderIsTarget)
                    {
                        changed++;
                        providers.Add(SourceProviderLabel(item));
                        if (buildOutput)
                        {
                            updatedBody = ReplaceOrAddProvider(line.Body, item);
                        }
                    }
                    masked.Append(RemoveProvider(line.Body, item));
                }
                else
                {
                    masked.Append(line.Body);
                }
                masked.Append(line.Ending);

                if (buildOutput)
                {
                    output.Append(updatedBody);
                    output.Append(line.Ending);
                }
            }

            string[] providerArray = new string[providers.Count];
            providers.CopyTo(providerArray);
            Array.Sort(providerArray, StringComparer.Ordinal);
            byte[] maskedBytes = StrictUtf8.GetBytes(masked.ToString());

            Analysis result = new Analysis();
            result.LineCount = lines.Count;
            result.CanonicalSessionId = canonicalSessionId;
            result.SessionIds = sessionIds.ToArray();
            result.SourceProviders = providerArray;
            result.ChangedMetaLines = changed;
            result.NonProviderSha256 = Sha256(maskedBytes);
            result.OutputBytes = buildOutput ? StrictUtf8.GetBytes(output.ToString()) : bytes;
            return result;
        }

        private static ParsedLine ParseLine(string body, bool firstLine, string path, int lineNumber)
        {
            int start = 0;
            if (firstLine && body.Length > 0 && body[0] == '\uFEFF')
            {
                start = 1;
            }
            start = SkipWhitespace(body, start);
            if (start == body.Length)
            {
                return new ParsedLine();
            }

            try
            {
                if (body[start] != '{')
                {
                    throw new JsonlMigrationException("Unexpected non-object JSONL item");
                }
                int end = ScanValue(body, start);
                if (SkipWhitespace(body, end) != body.Length)
                {
                    throw new JsonlMigrationException("Trailing content after JSON object");
                }

                List<JsonMember> topMembers = ObjectMembers(body, start);
                JsonMember typeMember = UniqueMember(topMembers, "type");
                string typeValue = StringValue(body, typeMember);
                if (!String.Equals(typeValue, "session_meta", StringComparison.Ordinal))
                {
                    return new ParsedLine();
                }

                JsonMember payloadMember = UniqueMember(topMembers, "payload");
                if (payloadMember == null || body[payloadMember.ValueStart] != '{')
                {
                    throw new JsonlMigrationException("session_meta line has no JSON object payload");
                }

                List<JsonMember> payloadMembers = ObjectMembers(body, payloadMember.ValueStart);
                string sessionId = null;
                for (int keyIndex = 0; keyIndex < SessionIdKeys.Length; keyIndex++)
                {
                    JsonMember idMember = UniqueMember(payloadMembers, SessionIdKeys[keyIndex]);
                    string candidate = StringValue(body, idMember);
                    if (candidate != null && candidate.Trim().Length > 0)
                    {
                        candidate = candidate.Trim();
                        if (sessionId == null)
                        {
                            sessionId = candidate;
                        }
                        else if (!String.Equals(sessionId, candidate, StringComparison.OrdinalIgnoreCase))
                        {
                            throw new JsonlMigrationException(
                                "session_meta contains conflicting id/session_id/thread_id values");
                        }
                    }
                }

                JsonMember providerMember = UniqueMember(payloadMembers, "model_provider");
                string providerString = StringValue(body, providerMember);
                ParsedLine parsed = new ParsedLine();
                parsed.IsSessionMeta = true;
                parsed.SessionId = sessionId;
                parsed.PayloadStart = payloadMember.ValueStart;
                parsed.PayloadEnd = payloadMember.ValueEnd;
                parsed.PayloadMembers = payloadMembers;
                parsed.ProviderMember = providerMember;
                parsed.ProviderString = providerString;
                parsed.ProviderIsTarget = providerMember != null &&
                    providerString != null &&
                    String.Equals(providerString, TargetProvider, StringComparison.Ordinal);
                return parsed;
            }
            catch (JsonlMigrationException error)
            {
                throw new JsonlMigrationException(
                    "Damaged JSONL at " + path + ":" + lineNumber.ToString(CultureInfo.InvariantCulture) +
                    ": " + error.Message,
                    error);
            }
        }

        private static string ResolveCanonicalSessionId(string path, List<string> sessionIds)
        {
            string filenameId = null;
            MatchCollection matches = UuidPattern.Matches(Path.GetFileNameWithoutExtension(path));
            if (matches.Count > 0)
            {
                filenameId = matches[matches.Count - 1].Value;
            }

            if (filenameId != null)
            {
                for (int index = 0; index < sessionIds.Count; index++)
                {
                    if (String.Equals(sessionIds[index], filenameId, StringComparison.OrdinalIgnoreCase))
                    {
                        return sessionIds[index];
                    }
                }
                if (sessionIds.Count > 0)
                {
                    throw new JsonlMigrationException(
                        "The UUID in the rollout filename does not match its session_meta ID: " + path);
                }
            }
            if (sessionIds.Count == 1)
            {
                return sessionIds[0];
            }
            if (sessionIds.Count > 0)
            {
                throw new JsonlMigrationException(
                    "Ambiguous session_meta IDs in " + path + "; refusing to change embedded/forked metadata.");
            }
            return null;
        }

        private static string ReplaceOrAddProvider(string body, ParsedLine item)
        {
            const string encodedProvider = "\"custom\"";
            if (item.ProviderMember != null)
            {
                return body.Substring(0, item.ProviderMember.ValueStart) + encodedProvider +
                    body.Substring(item.ProviderMember.ValueEnd);
            }

            int close = item.PayloadEnd - 1;
            string prefix = item.PayloadMembers.Count == 0 ? String.Empty : ",";
            return body.Substring(0, close) + prefix + "\"model_provider\":\"custom\"" + body.Substring(close);
        }

        private static string RemoveProvider(string body, ParsedLine item)
        {
            JsonMember provider = item.ProviderMember;
            if (provider == null)
            {
                return body;
            }

            int providerIndex = item.PayloadMembers.IndexOf(provider);
            if (provider.CommaAfter >= 0)
            {
                return body.Substring(0, provider.KeyStart) + body.Substring(provider.CommaAfter + 1);
            }
            if (providerIndex > 0)
            {
                JsonMember previous = item.PayloadMembers[providerIndex - 1];
                if (previous.CommaAfter < 0)
                {
                    throw new JsonlMigrationException("Could not locate model_provider separator.");
                }
                return body.Substring(0, previous.CommaAfter) + body.Substring(provider.ValueEnd);
            }
            return body.Substring(0, provider.KeyStart) + body.Substring(provider.ValueEnd);
        }

        private static string SourceProviderLabel(ParsedLine item)
        {
            if (item.ProviderMember == null || item.ProviderString == null)
            {
                return item.ProviderMember == null ? "<missing>" : "<invalid>";
            }
            if (item.ProviderString.Length == 0)
            {
                return "<missing>";
            }
            return item.ProviderString;
        }

        private static List<JsonLine> SplitPhysicalLines(string text)
        {
            List<JsonLine> result = new List<JsonLine>();
            int start = 0;
            int index = 0;
            while (index < text.Length)
            {
                if (text[index] == '\r')
                {
                    string ending = "\r";
                    int width = 1;
                    if (index + 1 < text.Length && text[index + 1] == '\n')
                    {
                        ending = "\r\n";
                        width = 2;
                    }
                    result.Add(new JsonLine(text.Substring(start, index - start), ending));
                    index += width;
                    start = index;
                    continue;
                }
                if (text[index] == '\n')
                {
                    result.Add(new JsonLine(text.Substring(start, index - start), "\n"));
                    index++;
                    start = index;
                    continue;
                }
                index++;
            }
            if (start < text.Length || result.Count == 0)
            {
                result.Add(new JsonLine(text.Substring(start), String.Empty));
            }
            return result;
        }

        private static int SkipWhitespace(string text, int index)
        {
            while (index < text.Length)
            {
                char value = text[index];
                if (value != ' ' && value != '\t' && value != '\r' && value != '\n')
                {
                    break;
                }
                index++;
            }
            return index;
        }

        private static int ScanString(string text, int index)
        {
            if (index >= text.Length || text[index] != '"')
            {
                throw new JsonlMigrationException("Expected a JSON string.");
            }
            index++;
            while (index < text.Length)
            {
                char value = text[index++];
                if (value == '"')
                {
                    return index;
                }
                if (value < 0x20)
                {
                    throw new JsonlMigrationException("Unescaped control character in JSON string.");
                }
                if (value == '\\')
                {
                    if (index >= text.Length)
                    {
                        throw new JsonlMigrationException("Unterminated JSON escape.");
                    }
                    char escape = text[index++];
                    if (escape == 'u')
                    {
                        if (index + 4 > text.Length || !AreHexDigits(text, index, 4))
                        {
                            throw new JsonlMigrationException("Invalid JSON Unicode escape.");
                        }
                        index += 4;
                    }
                    else if (escape != '"' && escape != '\\' && escape != '/' &&
                             escape != 'b' && escape != 'f' && escape != 'n' &&
                             escape != 'r' && escape != 't')
                    {
                        throw new JsonlMigrationException("Invalid JSON escape.");
                    }
                }
            }
            throw new JsonlMigrationException("Unterminated JSON string.");
        }

        private static int ScanValue(string text, int index)
        {
            index = SkipWhitespace(text, index);
            if (index >= text.Length)
            {
                throw new JsonlMigrationException("Unexpected end of JSON.");
            }
            char first = text[index];
            if (first == '"')
            {
                return ScanString(text, index);
            }
            if (first == '{')
            {
                index = SkipWhitespace(text, index + 1);
                if (index < text.Length && text[index] == '}')
                {
                    return index + 1;
                }
                while (true)
                {
                    index = ScanString(text, index);
                    index = SkipWhitespace(text, index);
                    if (index >= text.Length || text[index] != ':')
                    {
                        throw new JsonlMigrationException("Invalid JSON object member.");
                    }
                    index = ScanValue(text, index + 1);
                    index = SkipWhitespace(text, index);
                    if (index < text.Length && text[index] == ',')
                    {
                        index = SkipWhitespace(text, index + 1);
                        continue;
                    }
                    if (index < text.Length && text[index] == '}')
                    {
                        return index + 1;
                    }
                    throw new JsonlMigrationException("Invalid JSON object separator.");
                }
            }
            if (first == '[')
            {
                index = SkipWhitespace(text, index + 1);
                if (index < text.Length && text[index] == ']')
                {
                    return index + 1;
                }
                while (true)
                {
                    index = ScanValue(text, index);
                    index = SkipWhitespace(text, index);
                    if (index < text.Length && text[index] == ',')
                    {
                        index = SkipWhitespace(text, index + 1);
                        continue;
                    }
                    if (index < text.Length && text[index] == ']')
                    {
                        return index + 1;
                    }
                    throw new JsonlMigrationException("Invalid JSON array separator.");
                }
            }
            if (StartsWith(text, index, "true")) return index + 4;
            if (StartsWith(text, index, "false")) return index + 5;
            if (StartsWith(text, index, "null")) return index + 4;
            return ScanNumber(text, index);
        }

        private static int ScanNumber(string text, int index)
        {
            int cursor = index;
            if (cursor < text.Length && text[cursor] == '-') cursor++;
            if (cursor >= text.Length) throw new JsonlMigrationException("Invalid JSON number.");
            if (text[cursor] == '0')
            {
                cursor++;
            }
            else
            {
                if (text[cursor] < '1' || text[cursor] > '9')
                    throw new JsonlMigrationException("Invalid JSON value.");
                while (cursor < text.Length && text[cursor] >= '0' && text[cursor] <= '9') cursor++;
            }
            if (cursor < text.Length && text[cursor] == '.')
            {
                cursor++;
                int fractionStart = cursor;
                while (cursor < text.Length && text[cursor] >= '0' && text[cursor] <= '9') cursor++;
                if (cursor == fractionStart) throw new JsonlMigrationException("Invalid JSON fraction.");
            }
            if (cursor < text.Length && (text[cursor] == 'e' || text[cursor] == 'E'))
            {
                cursor++;
                if (cursor < text.Length && (text[cursor] == '+' || text[cursor] == '-')) cursor++;
                int exponentStart = cursor;
                while (cursor < text.Length && text[cursor] >= '0' && text[cursor] <= '9') cursor++;
                if (cursor == exponentStart) throw new JsonlMigrationException("Invalid JSON exponent.");
            }
            return cursor;
        }

        private static List<JsonMember> ObjectMembers(string text, int objectStart)
        {
            if (objectStart >= text.Length || text[objectStart] != '{')
            {
                throw new JsonlMigrationException("Expected a JSON object.");
            }
            List<JsonMember> members = new List<JsonMember>();
            int index = SkipWhitespace(text, objectStart + 1);
            if (index < text.Length && text[index] == '}')
            {
                return members;
            }
            while (true)
            {
                int keyStart = index;
                int keyEnd = ScanString(text, keyStart);
                string key = DecodeJsonString(text, keyStart, keyEnd);
                index = SkipWhitespace(text, keyEnd);
                if (index >= text.Length || text[index] != ':')
                {
                    throw new JsonlMigrationException("Invalid JSON member separator.");
                }
                int valueStart = SkipWhitespace(text, index + 1);
                int valueEnd = ScanValue(text, valueStart);
                index = SkipWhitespace(text, valueEnd);
                int commaAfter = -1;
                if (index < text.Length && text[index] == ',')
                {
                    commaAfter = index;
                    index = SkipWhitespace(text, index + 1);
                }
                else if (index >= text.Length || text[index] != '}')
                {
                    throw new JsonlMigrationException("Invalid JSON object terminator.");
                }
                members.Add(new JsonMember(key, keyStart, valueStart, valueEnd, commaAfter));
                if (commaAfter < 0)
                {
                    return members;
                }
            }
        }

        private static JsonMember UniqueMember(List<JsonMember> members, string key)
        {
            JsonMember result = null;
            for (int index = 0; index < members.Count; index++)
            {
                if (String.Equals(members[index].Key, key, StringComparison.Ordinal))
                {
                    if (result != null)
                    {
                        throw new JsonlMigrationException("Duplicate security-relevant JSON member: " + key);
                    }
                    result = members[index];
                }
            }
            return result;
        }

        private static string StringValue(string text, JsonMember member)
        {
            if (member == null || member.ValueStart >= text.Length || text[member.ValueStart] != '"')
            {
                return null;
            }
            int end = ScanString(text, member.ValueStart);
            if (end != member.ValueEnd)
            {
                return null;
            }
            return DecodeJsonString(text, member.ValueStart, end);
        }

        private static string DecodeJsonString(string text, int start, int end)
        {
            StringBuilder result = new StringBuilder(end - start - 2);
            int index = start + 1;
            while (index < end - 1)
            {
                char value = text[index++];
                if (value != '\\')
                {
                    result.Append(value);
                    continue;
                }
                char escape = text[index++];
                if (escape == '"' || escape == '\\' || escape == '/') result.Append(escape);
                else if (escape == 'b') result.Append('\b');
                else if (escape == 'f') result.Append('\f');
                else if (escape == 'n') result.Append('\n');
                else if (escape == 'r') result.Append('\r');
                else if (escape == 't') result.Append('\t');
                else if (escape == 'u')
                {
                    int code = Int32.Parse(text.Substring(index, 4), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture);
                    result.Append((char)code);
                    index += 4;
                }
                else
                {
                    throw new JsonlMigrationException("Invalid JSON escape.");
                }
            }
            return result.ToString();
        }

        private static bool AreHexDigits(string text, int start, int count)
        {
            for (int index = start; index < start + count; index++)
            {
                char value = text[index];
                if (!((value >= '0' && value <= '9') || (value >= 'a' && value <= 'f') || (value >= 'A' && value <= 'F')))
                    return false;
            }
            return true;
        }

        private static bool StartsWith(string text, int index, string value)
        {
            return index + value.Length <= text.Length &&
                String.CompareOrdinal(text, index, value, 0, value.Length) == 0;
        }

        private static StableRead ReadStable(string path)
        {
            FileInfo before = NewFileInfo(path);
            byte[] bytes;
            using (FileStream stream = new FileStream(
                path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete,
                131072, FileOptions.SequentialScan))
            {
                bytes = ReadAll(stream);
            }
            FileInfo after = NewFileInfo(path);
            if (before.Length != after.Length || before.LastWriteTimeUtc.Ticks != after.LastWriteTimeUtc.Ticks ||
                bytes.LongLength != after.Length)
            {
                throw new JsonlMigrationException("File changed while it was being read: " + path);
            }
            return new StableRead(bytes, after.Length, after.LastWriteTimeUtc.Ticks);
        }

        private static FileStream OpenReadDenyWriters(string path)
        {
            try
            {
                return new FileStream(
                    path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete,
                    131072, FileOptions.SequentialScan);
            }
            catch (IOException error)
            {
                throw new JsonlMigrationException(
                    "Could not lock rollout against concurrent writers; close Codex and retry: " + path,
                    error);
            }
        }

        private static byte[] ReadAll(FileStream stream)
        {
            stream.Position = 0;
            using (MemoryStream memory = stream.Length <= Int32.MaxValue
                ? new MemoryStream((int)stream.Length)
                : new MemoryStream())
            {
                byte[] buffer = new byte[131072];
                int read;
                while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
                {
                    memory.Write(buffer, 0, read);
                }
                return memory.ToArray();
            }
        }

        private static void WriteNewBackup(string backupPath, byte[] bytes, string expectedSha256)
        {
            string directory = Path.GetDirectoryName(backupPath);
            Directory.CreateDirectory(directory);
            string temporary = Path.Combine(directory, "." + Path.GetFileName(backupPath) + "." + Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                WriteBytesDurably(temporary, bytes);
                if (File.Exists(backupPath))
                {
                    throw new JsonlMigrationException("Backup already exists; refusing to overwrite it: " + backupPath);
                }
                File.Move(temporary, backupPath);
                temporary = null;
                StableRead backup = ReadStable(backupPath);
                if (!FixedTimeEquals(Sha256(backup.Bytes), expectedSha256) || !BytesEqual(backup.Bytes, bytes))
                {
                    throw new JsonlMigrationException("Backup verification failed: " + backupPath);
                }
            }
            finally
            {
                DeleteTemporary(temporary);
            }
        }

        private static string WriteReplacementTemp(string sourcePath, byte[] bytes)
        {
            string directory = Path.GetDirectoryName(sourcePath);
            string temporary = Path.Combine(directory, "." + Path.GetFileName(sourcePath) + "." + Guid.NewGuid().ToString("N") + ".tmp");
            WriteBytesDurably(temporary, bytes);
            return temporary;
        }

        private static string CreateReplacementBackupPath(string sourcePath)
        {
            string directory = Path.GetDirectoryName(sourcePath);
            string backup = Path.Combine(
                directory,
                "." + Path.GetFileName(sourcePath) + "." + Guid.NewGuid().ToString("N") + ".replace-backup");
            if (File.Exists(backup) || Directory.Exists(backup))
            {
                throw new JsonlMigrationException("Replacement backup path already exists: " + backup);
            }
            return backup;
        }

        private static void WriteBytesDurably(string path, byte[] bytes)
        {
            using (FileStream stream = new FileStream(
                path, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                131072, FileOptions.WriteThrough))
            {
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(true);
            }
        }

        private static void DeleteTemporary(string path)
        {
            if (path == null) return;
            try
            {
                if (File.Exists(path)) File.Delete(path);
            }
            catch
            {
                // Never hide the primary migration/rollback outcome because a
                // same-directory temporary file could not be cleaned up.
            }
        }

        private static string RequireExistingFile(string path)
        {
            if (String.IsNullOrWhiteSpace(path)) throw new ArgumentException("A file path is required.", "path");
            string fullPath = Path.GetFullPath(path);
            if (!File.Exists(fullPath)) throw new JsonlMigrationException("File was not found: " + fullPath);
            return fullPath;
        }

        private static string RequireNewBackupPath(string sourcePath, string backupPath)
        {
            if (String.IsNullOrWhiteSpace(backupPath))
                throw new ArgumentException("A backup path is required.", "backupPath");
            string fullBackupPath = Path.GetFullPath(backupPath);
            if (PathsEqual(sourcePath, fullBackupPath))
                throw new JsonlMigrationException("Backup path must differ from source path: " + sourcePath);
            if (File.Exists(fullBackupPath) || Directory.Exists(fullBackupPath))
                throw new JsonlMigrationException("Backup path already exists: " + fullBackupPath);
            return fullBackupPath;
        }

        private static bool PathsEqual(string left, string right)
        {
            return String.Equals(
                Path.GetFullPath(left).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                Path.GetFullPath(right).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                StringComparison.OrdinalIgnoreCase);
        }

        private static FileInfo NewFileInfo(string path)
        {
            FileInfo result = new FileInfo(path);
            result.Refresh();
            if (!result.Exists) throw new JsonlMigrationException("File disappeared during migration: " + path);
            return result;
        }

        private static string Sha256(byte[] bytes)
        {
            using (SHA256 algorithm = SHA256.Create())
            {
                byte[] digest = algorithm.ComputeHash(bytes);
                StringBuilder result = new StringBuilder(digest.Length * 2);
                for (int index = 0; index < digest.Length; index++)
                    result.Append(digest[index].ToString("x2", CultureInfo.InvariantCulture));
                return result.ToString();
            }
        }

        private static bool FixedTimeEquals(string left, string right)
        {
            if (left == null || right == null || left.Length != right.Length) return false;
            int difference = 0;
            for (int index = 0; index < left.Length; index++) difference |= left[index] ^ right[index];
            return difference == 0;
        }

        private static bool BytesEqual(byte[] left, byte[] right)
        {
            if (Object.ReferenceEquals(left, right)) return true;
            if (left == null || right == null || left.Length != right.Length) return false;
            int difference = 0;
            for (int index = 0; index < left.Length; index++) difference |= left[index] ^ right[index];
            return difference == 0;
        }

        private static string[] Copy(string[] values)
        {
            string[] result = new string[values.Length];
            Array.Copy(values, result, values.Length);
            return result;
        }

        private static bool StringArraysEqual(string[] left, string[] right)
        {
            if (left == null || right == null || left.Length != right.Length) return false;
            for (int index = 0; index < left.Length; index++)
                if (!String.Equals(left[index], right[index], StringComparison.Ordinal)) return false;
            return true;
        }

        private static void RequireSameShape(Analysis before, Analysis after, string path)
        {
            if (before.LineCount != after.LineCount ||
                !StringArraysEqual(before.SessionIds, after.SessionIds) ||
                !String.Equals(before.CanonicalSessionId, after.CanonicalSessionId, StringComparison.Ordinal))
            {
                throw new JsonlMigrationException("Session IDs or physical line count would change: " + path);
            }
        }

        private sealed class StableRead
        {
            internal StableRead(byte[] bytes, long length, long lastWriteUtcTicks)
            {
                this.Bytes = bytes;
                this.Length = length;
                this.LastWriteUtcTicks = lastWriteUtcTicks;
            }
            internal byte[] Bytes;
            internal long Length;
            internal long LastWriteUtcTicks;
        }

        private sealed class Analysis
        {
            internal int LineCount;
            internal string CanonicalSessionId;
            internal string[] SessionIds;
            internal string[] SourceProviders;
            internal int ChangedMetaLines;
            internal string NonProviderSha256;
            internal byte[] OutputBytes;
        }

        private sealed class JsonLine
        {
            internal JsonLine(string body, string ending) { this.Body = body; this.Ending = ending; }
            internal string Body;
            internal string Ending;
        }

        private sealed class JsonMember
        {
            internal JsonMember(string key, int keyStart, int valueStart, int valueEnd, int commaAfter)
            {
                this.Key = key;
                this.KeyStart = keyStart;
                this.ValueStart = valueStart;
                this.ValueEnd = valueEnd;
                this.CommaAfter = commaAfter;
            }
            internal string Key;
            internal int KeyStart;
            internal int ValueStart;
            internal int ValueEnd;
            internal int CommaAfter;
        }

        private sealed class ParsedLine
        {
            internal bool IsSessionMeta;
            internal string SessionId;
            internal int PayloadStart;
            internal int PayloadEnd;
            internal List<JsonMember> PayloadMembers;
            internal JsonMember ProviderMember;
            internal string ProviderString;
            internal bool ProviderIsTarget;
        }
    }
}
'@

$sqliteSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

// PowerShell 5.1 / .NET Framework compatible SQLite migration core.
// This source uses the SQLite library bundled with 64-bit Windows directly,
// keeping the final BAT self-contained on supported Windows installations.

public sealed class NativeSqliteMigrationResult
{
    public string DatabasePath { get; internal set; }
    public string BackupPath { get; internal set; }
    public bool ThreadsTablePresent { get; internal set; }
    public long TotalRows { get; internal set; }
    public long ChangedRows { get; internal set; }
    public string[] ThreadIds { get; internal set; }
    public string ThreadIdsSha256 { get; internal set; }
    public string BeforeNonProviderSha256 { get; internal set; }
    public string AfterNonProviderSha256 { get; internal set; }
    public string BeforeFullStateSha256 { get; internal set; }
    public string AfterFullStateSha256 { get; internal set; }
    public string BeforeStateFingerprint { get; internal set; }
    public string AfterStateFingerprint { get; internal set; }
}

// Read-only summary used before the user confirms a target CODEX_HOME.
// This makes automatic home discovery distinguish an initialized-but-empty
// state database from a real conversation store, without opening a write
// transaction or creating a backup.
public sealed class NativeSqliteInspectionResult
{
    public string DatabasePath { get; internal set; }
    public bool ThreadsTablePresent { get; internal set; }
    public long TotalRows { get; internal set; }
}

public sealed class NativeSqliteRestoreResult
{
    public string DatabasePath { get; internal set; }
    public string RestoredFromPath { get; internal set; }
    public string SafetyBackupPath { get; internal set; }
    public long TotalRows { get; internal set; }
    public string ThreadIdsSha256 { get; internal set; }
    public string NonProviderSha256 { get; internal set; }
    public string FullStateSha256 { get; internal set; }
    public string StateFingerprint { get; internal set; }
}

public sealed class NativeSqliteException : Exception
{
    public int ResultCode { get; private set; }
    public int ExtendedResultCode { get; private set; }

    internal NativeSqliteException(string message, int resultCode, int extendedResultCode)
        : base(message)
    {
        ResultCode = resultCode;
        ExtendedResultCode = extendedResultCode;
    }
}

public static class CodexNativeSqlite
{
    private const string TargetProvider = "custom";
    private const string StateDatabaseName = "state_5.sqlite";
    private const int DefaultBusyTimeoutMs = 10000;

    public static string LibraryVersion
    {
        get
        {
            return NativeMethods.PtrToUtf8Z(NativeMethods.sqlite3_libversion());
        }
    }

    // externalSqliteHome may be the root-level sqlite_home value from config.toml.
    // If it is null/empty, CODEX_SQLITE_HOME is considered. Returned paths are
    // candidates; the caller may filter them with Test-Path before migration.
    public static string[] GetCandidateDatabasePaths(string codexHome, string externalSqliteHome)
    {
        if (String.IsNullOrWhiteSpace(codexHome))
        {
            throw new ArgumentException("codexHome is required", "codexHome");
        }

        List<string> paths = new List<string>();
        AddDistinctPath(paths, Path.Combine(ExpandPath(codexHome), StateDatabaseName));

        string external = externalSqliteHome;
        if (String.IsNullOrWhiteSpace(external))
        {
            external = Environment.GetEnvironmentVariable("CODEX_SQLITE_HOME");
        }
        if (!String.IsNullOrWhiteSpace(external))
        {
            AddDistinctPath(paths, Path.Combine(ExpandPath(external), StateDatabaseName));
        }
        return paths.ToArray();
    }

    // This deliberately uses the same schema/integrity checks as migration,
    // but opens the state DB read-only and never starts a transaction.
    public static NativeSqliteInspectionResult InspectDatabase(
        string databasePath,
        int busyTimeoutMs)
    {
        string database = NormalizeExistingFile(databasePath, "databasePath");
        int timeout = NormalizeTimeout(busyTimeoutMs);
        using (NativeDb connection = NativeDb.OpenReadOnly(database, timeout))
        {
            connection.EnsureQuickCheck();
            Snapshot snapshot = Snapshot.Capture(connection);
            return new NativeSqliteInspectionResult
            {
                DatabasePath = database,
                ThreadsTablePresent = snapshot.ThreadsTablePresent,
                TotalRows = snapshot.TotalRows
            };
        }
    }

    // Read-only recovery aid for an outer durable ledger. A migration backup is
    // created before the UPDATE, so equality here proves that an interrupted
    // "changing" call did not leave threads in a committed provider state.
    public static bool HaveExactThreadsState(
        string firstDatabasePath,
        string secondDatabasePath,
        int busyTimeoutMs)
    {
        string first = NormalizeExistingFile(firstDatabasePath, "firstDatabasePath");
        string second = NormalizeExistingFile(secondDatabasePath, "secondDatabasePath");
        int timeout = NormalizeTimeout(busyTimeoutMs);
        using (NativeDb firstConnection = NativeDb.OpenReadOnly(first, timeout))
        using (NativeDb secondConnection = NativeDb.OpenReadOnly(second, timeout))
        {
            firstConnection.EnsureQuickCheck();
            secondConnection.EnsureQuickCheck();
            Snapshot firstSnapshot = Snapshot.Capture(firstConnection);
            Snapshot secondSnapshot = Snapshot.Capture(secondConnection);
            return firstSnapshot.IsExactMatch(secondSnapshot);
        }
    }

    public static NativeSqliteMigrationResult MigrateDatabase(
        string databasePath,
        string backupPath,
        int busyTimeoutMs)
    {
        string database = NormalizeExistingFile(databasePath, "databasePath");
        int timeout = NormalizeTimeout(busyTimeoutMs);

        NativeDb connection = null;
        bool transactionActive = false;
        Snapshot before = null;
        Snapshot after = null;
        string verifiedBackup = null;
        try
        {
            connection = NativeDb.OpenReadWriteExisting(database, timeout);
            connection.Execute("BEGIN IMMEDIATE");
            transactionActive = true;

            before = Snapshot.Capture(connection);
            if (!before.ThreadsTablePresent || before.NonCustomRows == 0)
            {
                connection.Execute("COMMIT");
                transactionActive = false;
                after = before;
                return BuildMigrationResult(database, null, before, after, 0);
            }

            // An UPDATE trigger could change another table while leaving every
            // hashed threads column untouched. Refuse such an unknown schema
            // instead of claiming that model_provider was the only mutation.
            connection.EnsureNoThreadsUpdateTriggers();

            if (String.IsNullOrWhiteSpace(backupPath))
            {
                throw new ArgumentException(
                    "backupPath is required when the database needs migration",
                    "backupPath");
            }

            string backup = NormalizeNewFile(backupPath, database, "backupPath");
            verifiedBackup = CreateVerifiedOnlineBackup(
                database,
                backup,
                before,
                timeout);

            using (NativeStatement update = connection.Prepare(
                "UPDATE \"threads\" SET \"model_provider\" = ?1 " +
                "WHERE \"model_provider\" IS NULL " +
                "OR typeof(\"model_provider\") <> 'text' " +
                "OR \"model_provider\" COLLATE BINARY <> ?2"))
            {
                update.BindText(1, TargetProvider);
                update.BindText(2, TargetProvider);
                update.ExpectDone();
            }

            long changed = connection.Changes;
            if (changed != before.NonCustomRows)
            {
                throw new InvalidOperationException(
                    "SQLite update count changed concurrently: expected " +
                    before.NonCustomRows.ToString(CultureInfo.InvariantCulture) +
                    ", got " + changed.ToString(CultureInfo.InvariantCulture));
            }

            after = Snapshot.Capture(connection);
            if (!before.HasSameNonProviderState(after))
            {
                throw new InvalidOperationException(
                    "SQLite content other than threads.model_provider changed during migration");
            }
            if (after.NonCustomRows != 0)
            {
                throw new InvalidOperationException(
                    "Not every threads.model_provider value became exactly 'custom'");
            }

            connection.Execute("COMMIT");
            transactionActive = false;
            return BuildMigrationResult(database, verifiedBackup, before, after, changed);
        }
        catch (Exception migrationError)
        {
            Exception rollbackError = null;
            if (connection != null && transactionActive && connection.IsTransactionActive)
            {
                try
                {
                    connection.Execute("ROLLBACK");
                    transactionActive = false;
                }
                catch (Exception error)
                {
                    rollbackError = error;
                }
            }
            if (rollbackError != null)
            {
                throw new InvalidOperationException(
                    "SQLite migration failed and ROLLBACK also failed. The verified online " +
                    "backup, if reported, must be used for recovery. Migration error: " +
                    migrationError.Message + "; rollback error: " + rollbackError.Message,
                    migrationError);
            }
            throw;
        }
        finally
        {
            if (connection != null)
            {
                connection.Dispose();
            }
        }
    }

    // Guarded recovery for a database that was committed by this migration.
    // The expected values must come from NativeSqliteMigrationResult: the
    // current-state guards use its AFTER fields and the backup authenticity
    // guard uses BeforeFullStateSha256. If either side changed, recovery is
    // refused.
    public static NativeSqliteRestoreResult RestoreDatabase(
        string backupPath,
        string databasePath,
        string safetyBackupPath,
        int busyTimeoutMs,
        long expectedTotalRows,
        string expectedThreadIdsSha256,
        string expectedAfterNonProviderSha256,
        string expectedAfterFullStateSha256,
        string expectedBeforeFullStateSha256)
    {
        string backup = NormalizeExistingFile(backupPath, "backupPath");
        string database = NormalizeExistingFile(databasePath, "databasePath");
        string safety = NormalizeNewFile(safetyBackupPath, database, "safetyBackupPath");
        EnsureDifferentPath(backup, database, "backupPath and databasePath must differ");
        EnsureDifferentPath(backup, safety, "backupPath and safetyBackupPath must differ");
        int timeout = NormalizeTimeout(busyTimeoutMs);

        Snapshot desired;
        using (NativeDb source = NativeDb.OpenReadOnly(backup, timeout))
        {
            source.EnsureQuickCheck();
            desired = Snapshot.Capture(source);
        }
        RequireExpectedBackupState(
            desired,
            expectedTotalRows,
            expectedThreadIdsSha256,
            expectedAfterNonProviderSha256,
            expectedBeforeFullStateSha256);

        // BEGIN IMMEDIATE makes the expected-state check and creation of the
        // safety backup consistent with one another. The transaction is released
        // immediately before the SQLite backup API atomically replaces the target.
        using (NativeDb target = NativeDb.OpenReadWriteExisting(database, timeout))
        {
            target.Execute("BEGIN IMMEDIATE");
            bool active = true;
            try
            {
                Snapshot current = Snapshot.Capture(target);
                RequireExpectedState(
                    current,
                    expectedTotalRows,
                    expectedThreadIdsSha256,
                    expectedAfterNonProviderSha256,
                    expectedAfterFullStateSha256);
                CreateVerifiedOnlineBackup(database, safety, current, timeout);
                target.Execute("COMMIT");
                active = false;
            }
            catch
            {
                if (active && target.IsTransactionActive)
                {
                    try { target.Execute("ROLLBACK"); }
                    catch { }
                }
                throw;
            }
        }

        // Recheck immediately before obtaining the destination write lock. This
        // prevents normal concurrent changes from being overwritten. The backup
        // API itself performs the replacement in an atomic SQLite transaction.
        using (NativeDb targetCheck = NativeDb.OpenReadOnly(database, timeout))
        {
            Snapshot current = Snapshot.Capture(targetCheck);
            RequireExpectedState(
                current,
                expectedTotalRows,
                expectedThreadIdsSha256,
                expectedAfterNonProviderSha256,
                expectedAfterFullStateSha256);
        }

        using (NativeDb source = NativeDb.OpenReadOnly(backup, timeout))
        using (NativeDb destination = NativeDb.OpenReadWriteExisting(database, timeout))
        {
            // sqlite3_backup_init refuses a destination with an active caller
            // transaction. EXCLUSIVE locking mode lets us validate under a
            // BEGIN EXCLUSIVE transaction, commit that transaction, and retain
            // the database lock on this same connection until OnlineCopy has
            // finished. This closes the check-to-backup TOCTOU window.
            destination.EnableExclusiveLockingMode();
            destination.Execute("BEGIN EXCLUSIVE");
            bool guardTransactionActive = true;
            try
            {
                Snapshot immediatelyBeforeCopy = Snapshot.Capture(destination);
                RequireExpectedState(
                    immediatelyBeforeCopy,
                    expectedTotalRows,
                    expectedThreadIdsSha256,
                    expectedAfterNonProviderSha256,
                    expectedAfterFullStateSha256);
                destination.Execute("COMMIT");
                guardTransactionActive = false;
                OnlineCopy(source, destination, timeout);
            }
            catch
            {
                if (guardTransactionActive && destination.IsTransactionActive)
                {
                    try { destination.Execute("ROLLBACK"); }
                    catch { }
                }
                throw;
            }
        }

        Snapshot restored;
        using (NativeDb check = NativeDb.OpenReadOnly(database, timeout))
        {
            check.EnsureQuickCheck();
            restored = Snapshot.Capture(check);
        }
        if (!desired.IsExactMatch(restored))
        {
            throw new InvalidOperationException(
                "Restored database did not match the verified backup. The safety backup " +
                "was preserved at: " + safety);
        }

        return new NativeSqliteRestoreResult
        {
            DatabasePath = database,
            RestoredFromPath = backup,
            SafetyBackupPath = safety,
            TotalRows = restored.TotalRows,
            ThreadIdsSha256 = restored.ThreadIdsSha256,
            NonProviderSha256 = restored.NonProviderSha256,
            FullStateSha256 = restored.FullStateSha256,
            StateFingerprint = restored.StateFingerprint
        };
    }

    private static NativeSqliteMigrationResult BuildMigrationResult(
        string database,
        string backup,
        Snapshot before,
        Snapshot after,
        long changed)
    {
        return new NativeSqliteMigrationResult
        {
            DatabasePath = database,
            BackupPath = backup,
            ThreadsTablePresent = before.ThreadsTablePresent,
            TotalRows = before.TotalRows,
            ChangedRows = changed,
            ThreadIds = (string[])before.ThreadIds.Clone(),
            ThreadIdsSha256 = before.ThreadIdsSha256,
            BeforeNonProviderSha256 = before.NonProviderSha256,
            AfterNonProviderSha256 = after.NonProviderSha256,
            BeforeFullStateSha256 = before.FullStateSha256,
            AfterFullStateSha256 = after.FullStateSha256,
            BeforeStateFingerprint = before.StateFingerprint,
            AfterStateFingerprint = after.StateFingerprint
        };
    }

    private static void RequireExpectedState(
        Snapshot current,
        long expectedTotalRows,
        string expectedThreadIdsSha256,
        string expectedNonProviderSha256,
        string expectedFullStateSha256)
    {
        bool matches = current.ThreadsTablePresent &&
            current.TotalRows == expectedTotalRows &&
            String.Equals(current.ThreadIdsSha256, expectedThreadIdsSha256, StringComparison.OrdinalIgnoreCase) &&
            String.Equals(current.NonProviderSha256, expectedNonProviderSha256, StringComparison.OrdinalIgnoreCase) &&
            String.Equals(current.FullStateSha256, expectedFullStateSha256, StringComparison.OrdinalIgnoreCase) &&
            current.NonCustomRows == 0;
        if (!matches)
        {
            throw new InvalidOperationException(
                "Recovery refused because the current database no longer matches the " +
                "migration's expected AFTER fingerprint");
        }
    }

    private static void RequireExpectedBackupState(
        Snapshot backup,
        long expectedTotalRows,
        string expectedThreadIdsSha256,
        string expectedNonProviderSha256,
        string expectedBeforeFullStateSha256)
    {
        bool matches = backup.ThreadsTablePresent &&
            backup.TotalRows == expectedTotalRows &&
            String.Equals(backup.ThreadIdsSha256, expectedThreadIdsSha256, StringComparison.OrdinalIgnoreCase) &&
            String.Equals(backup.NonProviderSha256, expectedNonProviderSha256, StringComparison.OrdinalIgnoreCase) &&
            String.Equals(backup.FullStateSha256, expectedBeforeFullStateSha256, StringComparison.OrdinalIgnoreCase);
        if (!matches)
        {
            throw new InvalidOperationException(
                "Recovery refused because the selected SQLite backup does not match " +
                "the migration's expected BEFORE fingerprint");
        }
    }

    private static string CreateVerifiedOnlineBackup(
        string sourceDatabase,
        string finalBackupPath,
        Snapshot expected,
        int timeout)
    {
        string parent = Path.GetDirectoryName(finalBackupPath);
        if (String.IsNullOrEmpty(parent))
        {
            throw new ArgumentException("Backup path must have a parent directory", "finalBackupPath");
        }
        Directory.CreateDirectory(parent);

        string temporary = finalBackupPath + ".building-" + Guid.NewGuid().ToString("N");
        bool moved = false;
        try
        {
            using (NativeDb source = NativeDb.OpenReadOnly(sourceDatabase, timeout))
            using (NativeDb destination = NativeDb.OpenReadWriteCreateNew(temporary, timeout))
            {
                OnlineCopy(source, destination, timeout);
            }

            using (NativeDb check = NativeDb.OpenReadOnly(temporary, timeout))
            {
                check.EnsureQuickCheck();
                Snapshot backupSnapshot = Snapshot.Capture(check);
                if (!expected.IsExactMatch(backupSnapshot))
                {
                    throw new InvalidOperationException(
                        "SQLite online backup did not match the locked source snapshot");
                }
            }

            if (File.Exists(finalBackupPath))
            {
                throw new IOException("Backup path appeared concurrently: " + finalBackupPath);
            }
            File.Move(temporary, finalBackupPath);
            moved = true;
            return finalBackupPath;
        }
        finally
        {
            if (!moved && File.Exists(temporary))
            {
                try { File.Delete(temporary); }
                catch { }
            }
        }
    }

    private static void OnlineCopy(NativeDb source, NativeDb destination, int timeout)
    {
        IntPtr backup = IntPtr.Zero;
        using (Utf8Buffer main = new Utf8Buffer("main"))
        {
            backup = NativeMethods.sqlite3_backup_init(
                destination.Handle,
                main.Pointer,
                source.Handle,
                main.Pointer);
        }
        if (backup == IntPtr.Zero)
        {
            destination.ThrowLastError("sqlite3_backup_init failed");
        }

        int stepResult = NativeMethods.SQLITE_OK;
        int finishResult = NativeMethods.SQLITE_OK;
        Stopwatch wait = Stopwatch.StartNew();
        try
        {
            while (true)
            {
                stepResult = NativeMethods.sqlite3_backup_step(backup, -1);
                int primary = NativeMethods.PrimaryResultCode(stepResult);
                if (primary == NativeMethods.SQLITE_DONE)
                {
                    break;
                }
                if ((primary == NativeMethods.SQLITE_BUSY || primary == NativeMethods.SQLITE_LOCKED) &&
                    wait.ElapsedMilliseconds < timeout)
                {
                    Thread.Sleep(50);
                    continue;
                }
                break;
            }
        }
        finally
        {
            finishResult = NativeMethods.sqlite3_backup_finish(backup);
        }

        if (NativeMethods.PrimaryResultCode(stepResult) != NativeMethods.SQLITE_DONE)
        {
            destination.ThrowResult(stepResult, "sqlite3_backup_step failed");
        }
        if (NativeMethods.PrimaryResultCode(finishResult) != NativeMethods.SQLITE_OK)
        {
            destination.ThrowResult(finishResult, "sqlite3_backup_finish failed");
        }
    }

    private static int NormalizeTimeout(int value)
    {
        if (value == 0)
        {
            return DefaultBusyTimeoutMs;
        }
        if (value < 1 || value > 300000)
        {
            throw new ArgumentOutOfRangeException(
                "busyTimeoutMs",
                "busyTimeoutMs must be between 1 and 300000, or zero for the default");
        }
        return value;
    }

    private static string NormalizeExistingFile(string value, string parameterName)
    {
        if (String.IsNullOrWhiteSpace(value))
        {
            throw new ArgumentException(parameterName + " is required", parameterName);
        }
        string path = ExpandPath(value);
        if (!File.Exists(path))
        {
            throw new FileNotFoundException("SQLite database does not exist", path);
        }
        FileAttributes attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new IOException(
                parameterName + " must not be a junction, symlink, or other reparse point: " + path);
        }
        return path;
    }

    private static string NormalizeNewFile(
        string value,
        string databasePath,
        string parameterName)
    {
        if (String.IsNullOrWhiteSpace(value))
        {
            throw new ArgumentException(parameterName + " is required", parameterName);
        }
        string path = ExpandPath(value);
        EnsureDifferentPath(path, databasePath, parameterName + " must differ from the database path");
        if (File.Exists(path) || Directory.Exists(path))
        {
            throw new IOException(parameterName + " already exists: " + path);
        }
        return path;
    }

    private static void EnsureDifferentPath(string first, string second, string message)
    {
        if (String.Equals(
            Path.GetFullPath(first).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
            Path.GetFullPath(second).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
            StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException(message);
        }
    }

    private static void AddDistinctPath(List<string> paths, string value)
    {
        string normalized = Path.GetFullPath(value);
        for (int i = 0; i < paths.Count; i++)
        {
            if (String.Equals(paths[i], normalized, StringComparison.OrdinalIgnoreCase))
            {
                return;
            }
        }
        paths.Add(normalized);
    }

    private static string ExpandPath(string value)
    {
        string expanded = Environment.ExpandEnvironmentVariables(value.Trim());
        if (expanded == "~" || expanded.StartsWith("~\\", StringComparison.Ordinal) ||
            expanded.StartsWith("~/", StringComparison.Ordinal))
        {
            string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if (expanded.Length == 1)
            {
                expanded = profile;
            }
            else
            {
                expanded = Path.Combine(profile, expanded.Substring(2));
            }
        }
        return Path.GetFullPath(expanded);
    }
}

internal sealed class Snapshot
{
    internal bool ThreadsTablePresent;
    internal SchemaColumn[] Columns;
    internal long TotalRows;
    internal long NonCustomRows;
    internal string[] ThreadIds;
    internal string ThreadIdsSha256;
    internal string NonProviderSha256;
    internal string ProviderSha256;
    internal string FullStateSha256;
    internal string StateFingerprint;

    internal static Snapshot Capture(NativeDb database)
    {
        SchemaColumn[] columns = ReadColumns(database);
        if (columns.Length == 0)
        {
            return CreateEmpty();
        }

        int idIndex = -1;
        int providerIndex = -1;
        for (int i = 0; i < columns.Length; i++)
        {
            if (String.Equals(columns[i].Name, "id", StringComparison.Ordinal))
            {
                idIndex = i;
            }
            if (String.Equals(columns[i].Name, "model_provider", StringComparison.Ordinal))
            {
                providerIndex = i;
            }
        }
        if (idIndex < 0 || providerIndex < 0)
        {
            throw new InvalidOperationException(
                "Codex threads table lacks the required id/model_provider columns");
        }

        string[] quoted = new string[columns.Length];
        for (int i = 0; i < columns.Length; i++)
        {
            quoted[i] = QuoteIdentifier(columns[i].Name);
        }
        string sql = "SELECT " + String.Join(", ", quoted) +
            " FROM \"threads\" ORDER BY " + QuoteIdentifier(columns[idIndex].Name);

        TypedHash idHash = new TypedHash("codex-thread-ids-v1");
        TypedHash nonProviderHash = new TypedHash("codex-threads-non-provider-v1");
        TypedHash providerHash = new TypedHash("codex-threads-provider-v1");
        TypedHash fullHash = new TypedHash("codex-threads-full-state-v1");
        List<string> ids = new List<string>();
        long rows = 0;
        long nonCustom = 0;
        try
        {
            WriteSchema(idHash, columns, new int[] { idIndex });
            List<int> nonProviderIndexes = new List<int>();
            List<int> allIndexes = new List<int>();
            for (int i = 0; i < columns.Length; i++)
            {
                allIndexes.Add(i);
                if (i != providerIndex)
                {
                    nonProviderIndexes.Add(i);
                }
            }
            WriteSchema(nonProviderHash, columns, nonProviderIndexes.ToArray());
            WriteSchema(providerHash, columns, new int[] { providerIndex });
            WriteSchema(fullHash, columns, allIndexes.ToArray());

            using (NativeStatement statement = database.Prepare(sql))
            {
                while (statement.Read())
                {
                    rows++;
                    idHash.WriteByte(0x52);
                    nonProviderHash.WriteByte(0x52);
                    providerHash.WriteByte(0x52);
                    fullHash.WriteByte(0x52);

                    for (int column = 0; column < columns.Length; column++)
                    {
                        SqliteValue value = statement.ReadValue(column);
                        fullHash.WriteValue(value);
                        if (column != providerIndex)
                        {
                            nonProviderHash.WriteValue(value);
                        }
                        if (column == idIndex)
                        {
                            idHash.WriteValue(value);
                            ids.Add(value.ToDisplayId());
                        }
                        if (column == providerIndex)
                        {
                            providerHash.WriteValue(value);
                            if (!value.IsExactUtf8Text(TargetProviderBytes))
                            {
                                nonCustom++;
                            }
                        }
                    }
                }
            }

            idHash.WriteInt64(rows);
            nonProviderHash.WriteInt64(rows);
            providerHash.WriteInt64(rows);
            fullHash.WriteInt64(rows);

            Snapshot snapshot = new Snapshot();
            snapshot.ThreadsTablePresent = true;
            snapshot.Columns = columns;
            snapshot.TotalRows = rows;
            snapshot.NonCustomRows = nonCustom;
            snapshot.ThreadIds = ids.ToArray();
            snapshot.ThreadIdsSha256 = idHash.Finish();
            snapshot.NonProviderSha256 = nonProviderHash.Finish();
            snapshot.ProviderSha256 = providerHash.Finish();
            snapshot.FullStateSha256 = fullHash.Finish();
            snapshot.StateFingerprint = BuildFingerprint(snapshot);
            return snapshot;
        }
        finally
        {
            idHash.Dispose();
            nonProviderHash.Dispose();
            providerHash.Dispose();
            fullHash.Dispose();
        }
    }

    internal bool HasSameNonProviderState(Snapshot other)
    {
        return other != null &&
            ThreadsTablePresent == other.ThreadsTablePresent &&
            SameSchema(Columns, other.Columns) &&
            TotalRows == other.TotalRows &&
            String.Equals(ThreadIdsSha256, other.ThreadIdsSha256, StringComparison.OrdinalIgnoreCase) &&
            String.Equals(NonProviderSha256, other.NonProviderSha256, StringComparison.OrdinalIgnoreCase) &&
            SameStrings(ThreadIds, other.ThreadIds);
    }

    internal bool IsExactMatch(Snapshot other)
    {
        return HasSameNonProviderState(other) &&
            NonCustomRows == other.NonCustomRows &&
            String.Equals(ProviderSha256, other.ProviderSha256, StringComparison.OrdinalIgnoreCase) &&
            String.Equals(FullStateSha256, other.FullStateSha256, StringComparison.OrdinalIgnoreCase) &&
            String.Equals(StateFingerprint, other.StateFingerprint, StringComparison.OrdinalIgnoreCase);
    }

    private static Snapshot CreateEmpty()
    {
        TypedHash empty = new TypedHash("codex-threads-empty-v1");
        string digest;
        try
        {
            empty.WriteInt64(0);
            digest = empty.Finish();
        }
        finally
        {
            empty.Dispose();
        }
        Snapshot value = new Snapshot();
        value.ThreadsTablePresent = false;
        value.Columns = new SchemaColumn[0];
        value.TotalRows = 0;
        value.NonCustomRows = 0;
        value.ThreadIds = new string[0];
        value.ThreadIdsSha256 = digest;
        value.NonProviderSha256 = digest;
        value.ProviderSha256 = digest;
        value.FullStateSha256 = digest;
        value.StateFingerprint = BuildFingerprint(value);
        return value;
    }

    private static SchemaColumn[] ReadColumns(NativeDb database)
    {
        List<SchemaColumn> columns = new List<SchemaColumn>();
        using (NativeStatement statement = database.Prepare("PRAGMA table_xinfo(\"threads\")"))
        {
            while (statement.Read())
            {
                SchemaColumn column = new SchemaColumn();
                column.Cid = statement.ReadValue(0).Integer;
                column.Name = statement.ReadValue(1).AsRequiredText("threads column name");
                column.DeclaredTypeToken = statement.ReadValue(2).ToStableToken();
                column.NotNull = statement.ReadValue(3).Integer;
                column.DefaultValueToken = statement.ReadValue(4).ToStableToken();
                column.PrimaryKey = statement.ReadValue(5).Integer;
                // table_xinfo.hidden is 0 for ordinary columns, 1 for hidden
                // virtual-table columns, 2 for VIRTUAL generated columns, and
                // 3 for STORED generated columns.
                column.Hidden = statement.ReadValue(6).Integer;
                columns.Add(column);
            }
        }
        return columns.ToArray();
    }

    private static void WriteSchema(TypedHash hash, SchemaColumn[] columns, int[] indexes)
    {
        hash.WriteInt64(indexes.Length);
        for (int i = 0; i < indexes.Length; i++)
        {
            SchemaColumn column = columns[indexes[i]];
            hash.WriteInt64(column.Cid);
            hash.WriteString(column.Name);
            hash.WriteString(column.DeclaredTypeToken);
            hash.WriteInt64(column.NotNull);
            hash.WriteString(column.DefaultValueToken);
            hash.WriteInt64(column.PrimaryKey);
            hash.WriteInt64(column.Hidden);
        }
    }

    private static bool SameSchema(SchemaColumn[] first, SchemaColumn[] second)
    {
        if (first == null || second == null || first.Length != second.Length)
        {
            return false;
        }
        for (int i = 0; i < first.Length; i++)
        {
            if (!first[i].EqualsColumn(second[i]))
            {
                return false;
            }
        }
        return true;
    }

    private static bool SameStrings(string[] first, string[] second)
    {
        if (first == null || second == null || first.Length != second.Length)
        {
            return false;
        }
        for (int i = 0; i < first.Length; i++)
        {
            if (!String.Equals(first[i], second[i], StringComparison.Ordinal))
            {
                return false;
            }
        }
        return true;
    }

    private static string BuildFingerprint(Snapshot snapshot)
    {
        TypedHash hash = new TypedHash("codex-threads-state-fingerprint-v1");
        try
        {
            hash.WriteByte(snapshot.ThreadsTablePresent ? (byte)1 : (byte)0);
            hash.WriteInt64(snapshot.TotalRows);
            hash.WriteInt64(snapshot.NonCustomRows);
            hash.WriteString(snapshot.ThreadIdsSha256);
            hash.WriteString(snapshot.NonProviderSha256);
            hash.WriteString(snapshot.ProviderSha256);
            hash.WriteString(snapshot.FullStateSha256);
            return hash.Finish();
        }
        finally
        {
            hash.Dispose();
        }
    }

    private static string QuoteIdentifier(string value)
    {
        return "\"" + value.Replace("\"", "\"\"") + "\"";
    }

    private static readonly byte[] TargetProviderBytes = Encoding.UTF8.GetBytes("custom");
}

internal sealed class SchemaColumn
{
    internal long Cid;
    internal string Name;
    internal string DeclaredTypeToken;
    internal long NotNull;
    internal string DefaultValueToken;
    internal long PrimaryKey;
    internal long Hidden;

    internal bool EqualsColumn(SchemaColumn other)
    {
        return other != null && Cid == other.Cid &&
            String.Equals(Name, other.Name, StringComparison.Ordinal) &&
            String.Equals(DeclaredTypeToken, other.DeclaredTypeToken, StringComparison.Ordinal) &&
            NotNull == other.NotNull &&
            String.Equals(DefaultValueToken, other.DefaultValueToken, StringComparison.Ordinal) &&
            PrimaryKey == other.PrimaryKey &&
            Hidden == other.Hidden;
    }
}

internal sealed class SqliteValue
{
    internal int Type;
    internal long Integer;
    internal long DoubleBits;
    internal byte[] Bytes;

    internal bool IsExactUtf8Text(byte[] expected)
    {
        if (Type != NativeMethods.SQLITE_TEXT || Bytes == null || Bytes.Length != expected.Length)
        {
            return false;
        }
        for (int i = 0; i < Bytes.Length; i++)
        {
            if (Bytes[i] != expected[i])
            {
                return false;
            }
        }
        return true;
    }

    internal string AsRequiredText(string description)
    {
        if (Type != NativeMethods.SQLITE_TEXT || Bytes == null)
        {
            throw new InvalidOperationException(description + " was not SQLite TEXT");
        }
        return Encoding.UTF8.GetString(Bytes);
    }

    internal string ToDisplayId()
    {
        if (Type == NativeMethods.SQLITE_TEXT)
        {
            return Encoding.UTF8.GetString(Bytes ?? new byte[0]);
        }
        return ToStableToken();
    }

    internal string ToStableToken()
    {
        if (Type == NativeMethods.SQLITE_NULL)
        {
            return "null";
        }
        if (Type == NativeMethods.SQLITE_INTEGER)
        {
            return "integer:" + Integer.ToString(CultureInfo.InvariantCulture);
        }
        if (Type == NativeMethods.SQLITE_FLOAT)
        {
            return "float-bits:" + DoubleBits.ToString("x16", CultureInfo.InvariantCulture);
        }
        byte[] bytes = Bytes ?? new byte[0];
        string digest;
        using (SHA256 sha = SHA256.Create())
        {
            digest = NativeMethods.ToHex(sha.ComputeHash(bytes));
        }
        return (Type == NativeMethods.SQLITE_TEXT ? "text:" : "blob:") +
            bytes.Length.ToString(CultureInfo.InvariantCulture) + ":" + digest;
    }
}

internal sealed class TypedHash : IDisposable
{
    private SHA256 hash;
    private bool finished;
    private readonly byte[] oneByte = new byte[1];
    private readonly byte[] eightBytes = new byte[8];

    internal TypedHash(string domain)
    {
        hash = SHA256.Create();
        WriteString(domain);
    }

    internal void WriteByte(byte value)
    {
        EnsureWritable();
        oneByte[0] = value;
        Append(oneByte, 0, 1);
    }

    internal void WriteInt64(long value)
    {
        EnsureWritable();
        unchecked
        {
            ulong bits = (ulong)value;
            for (int i = 0; i < 8; i++)
            {
                eightBytes[i] = (byte)(bits >> (i * 8));
            }
        }
        Append(eightBytes, 0, 8);
    }

    internal void WriteString(string value)
    {
        if (value == null)
        {
            WriteByte(0);
            return;
        }
        WriteByte(1);
        byte[] bytes = Encoding.UTF8.GetBytes(value);
        WriteInt64(bytes.LongLength);
        if (bytes.Length > 0)
        {
            Append(bytes, 0, bytes.Length);
        }
    }

    internal void WriteValue(SqliteValue value)
    {
        WriteByte((byte)value.Type);
        if (value.Type == NativeMethods.SQLITE_NULL)
        {
            return;
        }
        if (value.Type == NativeMethods.SQLITE_INTEGER)
        {
            WriteInt64(value.Integer);
            return;
        }
        if (value.Type == NativeMethods.SQLITE_FLOAT)
        {
            WriteInt64(value.DoubleBits);
            return;
        }
        byte[] bytes = value.Bytes ?? new byte[0];
        WriteInt64(bytes.LongLength);
        if (bytes.Length > 0)
        {
            Append(bytes, 0, bytes.Length);
        }
    }

    internal string Finish()
    {
        EnsureWritable();
        hash.TransformFinalBlock(new byte[0], 0, 0);
        finished = true;
        return NativeMethods.ToHex(hash.Hash);
    }

    private void Append(byte[] value, int offset, int count)
    {
        hash.TransformBlock(value, offset, count, value, offset);
    }

    private void EnsureWritable()
    {
        if (hash == null || finished)
        {
            throw new ObjectDisposedException("TypedHash");
        }
    }

    public void Dispose()
    {
        if (hash != null)
        {
            hash.Dispose();
            hash = null;
        }
    }
}

internal sealed class NativeDb : IDisposable
{
    internal IntPtr Handle { get; private set; }
    private readonly string path;

    private NativeDb(IntPtr handle, string databasePath, int timeout)
    {
        Handle = handle;
        path = databasePath;
        int extended = NativeMethods.sqlite3_extended_result_codes(handle, 1);
        if (NativeMethods.PrimaryResultCode(extended) != NativeMethods.SQLITE_OK)
        {
            ThrowResult(extended, "Could not enable SQLite extended result codes");
        }
        int busy = NativeMethods.sqlite3_busy_timeout(handle, timeout);
        if (NativeMethods.PrimaryResultCode(busy) != NativeMethods.SQLITE_OK)
        {
            ThrowResult(busy, "Could not set SQLite busy timeout");
        }
    }

    internal static NativeDb OpenReadOnly(string databasePath, int timeout)
    {
        return Open(databasePath, NativeMethods.SQLITE_OPEN_READONLY, timeout);
    }

    internal static NativeDb OpenReadWriteExisting(string databasePath, int timeout)
    {
        return Open(databasePath, NativeMethods.SQLITE_OPEN_READWRITE, timeout);
    }

    internal static NativeDb OpenReadWriteCreateNew(string databasePath, int timeout)
    {
        if (File.Exists(databasePath) || Directory.Exists(databasePath))
        {
            throw new IOException("SQLite destination already exists: " + databasePath);
        }
        return Open(
            databasePath,
            NativeMethods.SQLITE_OPEN_READWRITE |
            NativeMethods.SQLITE_OPEN_CREATE |
            NativeMethods.SQLITE_OPEN_EXCLUSIVE,
            timeout);
    }

    private static NativeDb Open(string databasePath, int flags, int timeout)
    {
        IntPtr handle = IntPtr.Zero;
        int result;
        using (Utf8Buffer fileName = new Utf8Buffer(databasePath))
        {
            result = NativeMethods.sqlite3_open_v2(
                fileName.Pointer,
                out handle,
                flags | NativeMethods.SQLITE_OPEN_FULLMUTEX,
                IntPtr.Zero);
        }
        if (NativeMethods.PrimaryResultCode(result) != NativeMethods.SQLITE_OK)
        {
            string message = handle == IntPtr.Zero
                ? "No SQLite error text was available"
                : NativeMethods.PtrToUtf8Z(NativeMethods.sqlite3_errmsg(handle));
            int extended = handle == IntPtr.Zero
                ? result
                : NativeMethods.sqlite3_extended_errcode(handle);
            if (handle != IntPtr.Zero)
            {
                NativeMethods.sqlite3_close_v2(handle);
            }
            throw new NativeSqliteException(
                "Could not open SQLite database '" + databasePath + "': " + message,
                result,
                extended);
        }
        try
        {
            return new NativeDb(handle, databasePath, timeout);
        }
        catch
        {
            NativeMethods.sqlite3_close_v2(handle);
            throw;
        }
    }

    internal NativeStatement Prepare(string sql)
    {
        EnsureOpen();
        IntPtr statement = IntPtr.Zero;
        IntPtr tail = IntPtr.Zero;
        int result;
        using (Utf8Buffer query = new Utf8Buffer(sql))
        {
            result = NativeMethods.sqlite3_prepare_v2(
                Handle,
                query.Pointer,
                query.ByteCount,
                out statement,
                out tail);
        }
        if (NativeMethods.PrimaryResultCode(result) != NativeMethods.SQLITE_OK)
        {
            ThrowResult(result, "Could not prepare SQLite statement");
        }
        if (statement == IntPtr.Zero)
        {
            throw new InvalidOperationException("SQLite prepared an empty statement");
        }
        return new NativeStatement(this, statement);
    }

    internal void Execute(string sql)
    {
        using (NativeStatement statement = Prepare(sql))
        {
            statement.ExpectDone();
        }
    }

    internal long Changes
    {
        get
        {
            EnsureOpen();
            return NativeMethods.sqlite3_changes(Handle);
        }
    }

    internal bool IsTransactionActive
    {
        get
        {
            return Handle != IntPtr.Zero && NativeMethods.sqlite3_get_autocommit(Handle) == 0;
        }
    }

    internal void EnsureQuickCheck()
    {
        int rows = 0;
        using (NativeStatement statement = Prepare("PRAGMA quick_check"))
        {
            while (statement.Read())
            {
                rows++;
                string result = statement.ReadValue(0).AsRequiredText("PRAGMA quick_check result");
                if (!String.Equals(result, "ok", StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException("SQLite quick_check failed: " + result);
                }
            }
        }
        if (rows != 1)
        {
            throw new InvalidOperationException(
                "SQLite quick_check returned an unexpected number of rows: " +
                rows.ToString(CultureInfo.InvariantCulture));
        }
    }

    internal void EnsureNoThreadsUpdateTriggers()
    {
        long count = -1;
        int rows = 0;
        using (NativeStatement statement = Prepare(
            "SELECT count(*) FROM \"sqlite_master\" " +
            "WHERE \"type\" = 'trigger' AND \"tbl_name\" = 'threads'"))
        {
            while (statement.Read())
            {
                rows++;
                SqliteValue value = statement.ReadValue(0);
                if (value.Type != NativeMethods.SQLITE_INTEGER)
                {
                    throw new InvalidOperationException(
                        "SQLite trigger count was not an INTEGER");
                }
                count = value.Integer;
            }
        }
        if (rows != 1 || count < 0)
        {
            throw new InvalidOperationException(
                "Could not determine whether the threads table has triggers");
        }
        if (count != 0)
        {
            throw new InvalidOperationException(
                "The threads table has update-capable triggers; refusing a provider-only migration");
        }
    }

    internal void EnableExclusiveLockingMode()
    {
        string mode = null;
        int rows = 0;
        using (NativeStatement statement = Prepare("PRAGMA locking_mode=EXCLUSIVE"))
        {
            while (statement.Read())
            {
                rows++;
                mode = statement.ReadValue(0).AsRequiredText("PRAGMA locking_mode result");
            }
        }
        if (rows != 1 || !String.Equals(mode, "exclusive", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                "SQLite refused the exclusive locking mode required for guarded recovery");
        }
    }

    internal void ThrowLastError(string context)
    {
        int code = NativeMethods.sqlite3_extended_errcode(Handle);
        ThrowResult(code, context);
    }

    internal void ThrowResult(int result, string context)
    {
        int extended = Handle == IntPtr.Zero ? result : NativeMethods.sqlite3_extended_errcode(Handle);
        string message = Handle == IntPtr.Zero
            ? "No SQLite error text was available"
            : NativeMethods.PtrToUtf8Z(NativeMethods.sqlite3_errmsg(Handle));
        throw new NativeSqliteException(
            context + " for '" + path + "': " + message,
            NativeMethods.PrimaryResultCode(result),
            extended);
    }

    private void EnsureOpen()
    {
        if (Handle == IntPtr.Zero)
        {
            throw new ObjectDisposedException("NativeDb");
        }
    }

    public void Dispose()
    {
        if (Handle != IntPtr.Zero)
        {
            int result = NativeMethods.sqlite3_close_v2(Handle);
            Handle = IntPtr.Zero;
            if (NativeMethods.PrimaryResultCode(result) != NativeMethods.SQLITE_OK)
            {
                // All statements in this draft are deterministically finalized.
                // close_v2 errors here cannot be safely recovered from Dispose.
            }
        }
    }
}

internal sealed class NativeStatement : IDisposable
{
    private NativeDb database;
    private IntPtr handle;
    private bool done;

    internal NativeStatement(NativeDb owner, IntPtr statement)
    {
        database = owner;
        handle = statement;
    }

    internal void BindText(int index, string value)
    {
        EnsureOpen();
        int result;
        using (Utf8Buffer text = new Utf8Buffer(value))
        {
            result = NativeMethods.sqlite3_bind_text(
                handle,
                index,
                text.Pointer,
                text.ByteCount,
                NativeMethods.SQLITE_TRANSIENT);
        }
        if (NativeMethods.PrimaryResultCode(result) != NativeMethods.SQLITE_OK)
        {
            database.ThrowResult(result, "Could not bind SQLite TEXT parameter");
        }
    }

    internal bool Read()
    {
        EnsureOpen();
        if (done)
        {
            return false;
        }
        int result = NativeMethods.sqlite3_step(handle);
        int primary = NativeMethods.PrimaryResultCode(result);
        if (primary == NativeMethods.SQLITE_ROW)
        {
            return true;
        }
        if (primary == NativeMethods.SQLITE_DONE)
        {
            done = true;
            return false;
        }
        database.ThrowResult(result, "Could not read SQLite statement");
        return false;
    }

    internal void ExpectDone()
    {
        EnsureOpen();
        int result = NativeMethods.sqlite3_step(handle);
        if (NativeMethods.PrimaryResultCode(result) != NativeMethods.SQLITE_DONE)
        {
            database.ThrowResult(result, "SQLite statement did not complete");
        }
        done = true;
    }

    internal SqliteValue ReadValue(int index)
    {
        EnsureOpen();
        int type = NativeMethods.sqlite3_column_type(handle, index);
        SqliteValue value = new SqliteValue();
        value.Type = type;
        if (type == NativeMethods.SQLITE_NULL)
        {
            return value;
        }
        if (type == NativeMethods.SQLITE_INTEGER)
        {
            value.Integer = NativeMethods.sqlite3_column_int64(handle, index);
            return value;
        }
        if (type == NativeMethods.SQLITE_FLOAT)
        {
            value.DoubleBits = BitConverter.DoubleToInt64Bits(
                NativeMethods.sqlite3_column_double(handle, index));
            return value;
        }
        // SQLite requires callers to obtain the converted TEXT/BLOB pointer
        // before asking for its byte length. Reversing this order can report a
        // length for a different transient representation.
        IntPtr pointer = type == NativeMethods.SQLITE_TEXT
            ? NativeMethods.sqlite3_column_text(handle, index)
            : NativeMethods.sqlite3_column_blob(handle, index);
        int length = NativeMethods.sqlite3_column_bytes(handle, index);
        if (length < 0 || (length > 0 && pointer == IntPtr.Zero))
        {
            database.ThrowLastError("Could not read SQLite column bytes");
        }
        value.Bytes = new byte[length];
        if (length > 0)
        {
            Marshal.Copy(pointer, value.Bytes, 0, length);
        }
        return value;
    }

    private void EnsureOpen()
    {
        if (handle == IntPtr.Zero)
        {
            throw new ObjectDisposedException("NativeStatement");
        }
    }

    public void Dispose()
    {
        if (handle != IntPtr.Zero)
        {
            NativeMethods.sqlite3_finalize(handle);
            handle = IntPtr.Zero;
            database = null;
        }
    }
}

internal sealed class Utf8Buffer : IDisposable
{
    internal IntPtr Pointer { get; private set; }
    internal int ByteCount { get; private set; }

    internal Utf8Buffer(string value)
    {
        if (value == null)
        {
            throw new ArgumentNullException("value");
        }
        if (value.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("SQLite strings cannot contain NUL", "value");
        }
        byte[] bytes = Encoding.UTF8.GetBytes(value);
        ByteCount = bytes.Length;
        Pointer = Marshal.AllocHGlobal(bytes.Length + 1);
        if (bytes.Length > 0)
        {
            Marshal.Copy(bytes, 0, Pointer, bytes.Length);
        }
        Marshal.WriteByte(Pointer, bytes.Length, 0);
    }

    public void Dispose()
    {
        if (Pointer != IntPtr.Zero)
        {
            Marshal.FreeHGlobal(Pointer);
            Pointer = IntPtr.Zero;
        }
    }
}

internal static class NativeMethods
{
    internal const int SQLITE_OK = 0;
    internal const int SQLITE_BUSY = 5;
    internal const int SQLITE_LOCKED = 6;
    internal const int SQLITE_ROW = 100;
    internal const int SQLITE_DONE = 101;
    internal const int SQLITE_INTEGER = 1;
    internal const int SQLITE_FLOAT = 2;
    internal const int SQLITE_TEXT = 3;
    internal const int SQLITE_BLOB = 4;
    internal const int SQLITE_NULL = 5;
    internal const int SQLITE_OPEN_READONLY = 0x00000001;
    internal const int SQLITE_OPEN_READWRITE = 0x00000002;
    internal const int SQLITE_OPEN_CREATE = 0x00000004;
    internal const int SQLITE_OPEN_EXCLUSIVE = 0x00000010;
    internal const int SQLITE_OPEN_FULLMUTEX = 0x00010000;
    internal static readonly IntPtr SQLITE_TRANSIENT = new IntPtr(-1);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern IntPtr sqlite3_libversion();

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int sqlite3_open_v2(
        IntPtr filename,
        out IntPtr database,
        int flags,
        IntPtr vfs);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int sqlite3_close_v2(IntPtr database);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int sqlite3_extended_result_codes(IntPtr database, int enabled);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int sqlite3_extended_errcode(IntPtr database);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern IntPtr sqlite3_errmsg(IntPtr database);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int sqlite3_busy_timeout(IntPtr database, int milliseconds);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int sqlite3_get_autocommit(IntPtr database);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int sqlite3_prepare_v2(
        IntPtr database,
        IntPtr sql,
        int byteCount,
        out IntPtr statement,
        out IntPtr tail);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int sqlite3_bind_text(
        IntPtr statement,
        int index,
        IntPtr value,
        int byteCount,
        IntPtr destructor);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int sqlite3_step(IntPtr statement);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int sqlite3_finalize(IntPtr statement);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int sqlite3_column_type(IntPtr statement, int column);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern long sqlite3_column_int64(IntPtr statement, int column);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern double sqlite3_column_double(IntPtr statement, int column);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern IntPtr sqlite3_column_text(IntPtr statement, int column);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern IntPtr sqlite3_column_blob(IntPtr statement, int column);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int sqlite3_column_bytes(IntPtr statement, int column);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int sqlite3_changes(IntPtr database);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern IntPtr sqlite3_backup_init(
        IntPtr destinationDatabase,
        IntPtr destinationName,
        IntPtr sourceDatabase,
        IntPtr sourceName);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int sqlite3_backup_step(IntPtr backup, int pages);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int sqlite3_backup_finish(IntPtr backup);

    internal static int PrimaryResultCode(int value)
    {
        return value & 0xff;
    }

    internal static string PtrToUtf8Z(IntPtr pointer)
    {
        if (pointer == IntPtr.Zero)
        {
            return String.Empty;
        }
        int length = 0;
        while (Marshal.ReadByte(pointer, length) != 0)
        {
            length++;
        }
        byte[] bytes = new byte[length];
        if (length > 0)
        {
            Marshal.Copy(pointer, bytes, 0, length);
        }
        return Encoding.UTF8.GetString(bytes);
    }

    internal static string ToHex(byte[] value)
    {
        StringBuilder result = new StringBuilder(value.Length * 2);
        for (int i = 0; i < value.Length; i++)
        {
            result.Append(value[i].ToString("x2", CultureInfo.InvariantCulture));
        }
        return result.ToString();
    }
}
'@

try {
    Add-Type -TypeDefinition $jsonlSource -Language CSharp -ErrorAction Stop
    Add-Type -TypeDefinition $sqliteSource -Language CSharp -ErrorAction Stop
    [void][CodexNativeSqlite]::LibraryVersion
    [Console]::WriteLine("[codex-lightweight][BOOT] Embedded JSONL/SQLite components loaded; winsqlite3=" + [CodexNativeSqlite]::LibraryVersion)
}
catch {
    [Console]::Error.WriteLine("[codex-lightweight][BOOT][ERROR] Embedded Windows component could not be loaded: $($_.Exception.Message)")
    [Console]::Error.WriteLine("[codex-lightweight][BOOT][TYPE] $($_.Exception.GetType().FullName)")
    exit 1
}
finally {
    $jsonlSource = $null
    $sqliteSource = $null
}

# PowerShell 5.1 orchestration draft for the dependency-free Windows BAT.
#
# Integration contract:
#   1. The final BAT embeds and compiles the C# implementations before this
#      payload is executed.
#   2. CodexLightweight.JsonlMigration is supplied by native_jsonl.
#   3. CodexNativeSqlite is supplied by native_sqlite.
#
# This draft intentionally contains no Add-Type payload. It is not an entry
# point and must not be distributed on its own.

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = New-Object Text.UTF8Encoding($false)

# Beginner entry: editable values are declared at the top of this BAT.
$managedBaseUrl = [string]$env:CODEX_LIGHTWEIGHT_BASE_URL
$managedApiKey = [string]$env:CODEX_LIGHTWEIGHT_API_KEY
$targetProvider = "custom"
$managedDefaultModel = [string]$env:CODEX_LIGHTWEIGHT_DEFAULT_MODEL
$managedReasoningEffort = [string]$env:CODEX_LIGHTWEIGHT_REASONING_EFFORT
foreach ($requiredSetting in @(
    @{ Name = 'Base URL'; Value = $managedBaseUrl },
    @{ Name = 'API Key'; Value = $managedApiKey },
    @{ Name = 'Default model'; Value = $managedDefaultModel },
    @{ Name = 'Reasoning effort'; Value = $managedReasoningEffort }
)) {
    if ([string]::IsNullOrWhiteSpace([string]$requiredSetting.Value)) {
        throw "Editable BAT setting is empty: $($requiredSetting.Name)"
    }
}
$migrationFormat = "codex-lightweight-native-v1"
$sqliteBusyTimeoutMs = 10000
$diagnosticMode = $true
$script:lightweightStartedUtc = [DateTime]::UtcNow

function Write-Step([string]$Message) {
    $timestamp = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff')
    Write-Host "[codex-lightweight][$timestamp][STEP] $Message"
}

function Write-Diagnostic([string]$Stage, [string]$Message) {
    if (-not $diagnosticMode) { return }
    $timestamp = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff')
    Write-Host "[codex-lightweight][$timestamp][TRACE][$Stage] $Message" -ForegroundColor DarkGray
}

function Get-ShortSha256([string]$Hash) {
    if ([string]::IsNullOrWhiteSpace($Hash)) { return '<none>' }
    if ($Hash.Length -le 16) { return $Hash }
    return $Hash.Substring(0, 16)
}

function Get-Sha256HexFromBytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-Sha256HexFromText([string]$Value) {
    $encoding = New-Object Text.UTF8Encoding($false)
    return Get-Sha256HexFromBytes $encoding.GetBytes($Value)
}

function Get-FileSnapshot([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File does not exist: $Path"
    }

    $before = Get-Item -LiteralPath $Path -Force
    $stream = New-Object IO.FileStream(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite
    )
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
    $after = Get-Item -LiteralPath $Path -Force
    if ($before.Length -ne $after.Length -or
        $before.LastWriteTimeUtc.Ticks -ne $after.LastWriteTimeUtc.Ticks) {
        throw "File changed while it was being read: $Path"
    }

    return [pscustomobject]@{
        Path = [IO.Path]::GetFullPath($Path)
        Length = [int64]$after.Length
        LastWriteUtcTicks = [int64]$after.LastWriteTimeUtc.Ticks
        Sha256 = $hash
    }
}

function Test-SnapshotEqual($Left, $Right) {
    return $null -ne $Left -and $null -ne $Right -and
        $Left.Length -eq $Right.Length -and
        $Left.LastWriteUtcTicks -eq $Right.LastWriteUtcTicks -and
        $Left.Sha256 -eq $Right.Sha256
}

function Read-Utf8FileStrict([string]$Path) {
    $snapshot = Get-FileSnapshot $Path
    $bytes = [IO.File]::ReadAllBytes($Path)
    $afterRead = Get-FileSnapshot $Path
    if (-not (Test-SnapshotEqual $snapshot $afterRead)) {
        throw "File changed while it was being read: $Path"
    }

    $hasBom = $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    try {
        $text = $strictUtf8.GetString($bytes, $offset, $bytes.Length - $offset)
    }
    catch {
        throw "File is not valid UTF-8: $Path"
    }

    return [pscustomobject]@{
        Bytes = $bytes
        Text = $text
        HasBom = $hasBom
        Snapshot = $snapshot
    }
}

function Read-ConfigForForcedReplacement([string]$Path) {
    $snapshot = Get-FileSnapshot $Path
    $bytes = [IO.File]::ReadAllBytes($Path)
    $afterRead = Get-FileSnapshot $Path
    if (-not (Test-SnapshotEqual $snapshot $afterRead)) {
        throw "Config changed while it was being read for backup: $Path"
    }

    $hasBom = $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    $encodingValid = $true
    try {
        $text = $strictUtf8.GetString($bytes, $offset, $bytes.Length - $offset)
    }
    catch {
        $text = ''
        $encodingValid = $false
        Write-Diagnostic 'CONFIG' 'Existing config.toml is not valid UTF-8. Its raw bytes will still be backed up before the forced replacement.'
    }

    return [pscustomobject]@{
        Bytes = $bytes
        Text = $text
        HasBom = $hasBom
        EncodingValid = $encodingValid
        Snapshot = $snapshot
    }
}

function ConvertTo-Utf8Bytes([string]$Text, [bool]$WithBom) {
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    $body = $encoding.GetBytes($Text)
    if (-not $WithBom) {
        return $body
    }
    $preamble = [byte[]](0xEF, 0xBB, 0xBF)
    $output = New-Object byte[] ($preamble.Length + $body.Length)
    [Array]::Copy($preamble, 0, $output, 0, $preamble.Length)
    [Array]::Copy($body, 0, $output, $preamble.Length, $body.Length)
    return $output
}

function Write-NewFileDurable([string]$Path, [byte[]]$Bytes) {
    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to overwrite an existing backup: $Path"
    }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $stream = New-Object IO.FileStream(
        $Path,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None,
        4096,
        [IO.FileOptions]::WriteThrough
    )
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function Write-FileAtomic(
    [string]$Path,
    [byte[]]$Bytes,
    $ExpectedSnapshot
) {
    $current = Get-FileSnapshot $Path
    if (-not (Test-SnapshotEqual $ExpectedSnapshot $current)) {
        throw "File changed concurrently before replacement: $Path"
    }

    $directory = Split-Path -Parent $Path
    $temporary = Join-Path $directory (".{0}.{1}.tmp" -f ([IO.Path]::GetFileName($Path)), [Guid]::NewGuid().ToString("N"))
    $replaceBackup = Join-Path $directory (".{0}.{1}.replace-backup" -f ([IO.Path]::GetFileName($Path)), [Guid]::NewGuid().ToString("N"))
    try {
        Write-NewFileDurable $temporary $Bytes
        $beforeReplace = Get-FileSnapshot $Path
        if (-not (Test-SnapshotEqual $ExpectedSnapshot $beforeReplace)) {
            throw "File changed concurrently during replacement: $Path"
        }
        # .NET Framework on some supported Windows builds rejects a null
        # replacement-backup path. Use a same-directory, unique scratch backup
        # so ReplaceFile remains atomic; the durable ledger owns the real backup.
        [IO.File]::Replace($temporary, $Path, $replaceBackup, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $replaceBackup) {
            Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-AtomicTextFile([string]$Path, [string]$Text) {
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Text)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporary = Join-Path $directory (".{0}.{1}.tmp" -f ([IO.Path]::GetFileName($Path)), [Guid]::NewGuid().ToString("N"))
    $replaceBackup = Join-Path $directory (".{0}.{1}.replace-backup" -f ([IO.Path]::GetFileName($Path)), [Guid]::NewGuid().ToString("N"))
    try {
        Write-NewFileDurable $temporary $bytes
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($temporary, $Path, $replaceBackup, $true)
        }
        else {
            [IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $replaceBackup) {
            Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-AbsolutePath([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "A required path is empty."
    }
    $raw = $Value.Trim()
    if ($raw.Length -ge 2 -and $raw.StartsWith('"') -and $raw.EndsWith('"')) {
        $raw = $raw.Substring(1, $raw.Length - 2)
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($raw)
    if ($expanded -eq "~") {
        $expanded = $env:USERPROFILE
    }
    elseif ($expanded.StartsWith("~\") -or $expanded.StartsWith("~/")) {
        $expanded = Join-Path $env:USERPROFILE $expanded.Substring(2)
    }
    return [IO.Path]::GetFullPath($expanded)
}

function Test-PathInside([string]$Path, [string]$Root) {
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return $fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith(
            "$fullRoot$([IO.Path]::DirectorySeparatorChar)",
            [StringComparison]::OrdinalIgnoreCase
        )
}

function Assert-NotReparsePoint([string]$Path, [string]$Label) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label must not be a junction, symlink, or other reparse point: $($item.FullName)"
    }
}

function Get-TomlTableName([string]$Line) {
    $match = [regex]::Match($Line, '^\s*\[([^\[\]]+)\]\s*(?:#.*)?$')
    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }
    $arrayMatch = [regex]::Match($Line, '^\s*\[\[([^\[\]]+)\]\]\s*(?:#.*)?$')
    if ($arrayMatch.Success) {
        return $arrayMatch.Groups[1].Value.Trim()
    }
    return $null
}

function Test-IsAnyTomlHeader([string]$Line) {
    return [regex]::IsMatch($Line, '^\s*\[(?:\[[^\r\n]+\]\]|[^\r\n]+\])\s*(?:#.*)?$')
}

function Split-ConfigLines([string]$Text) {
    $newline = if ($Text.Contains("`r`n")) { "`r`n" } elseif ($Text.Contains("`n")) { "`n" } else { "`r`n" }
    $terminalNewline = $Text.EndsWith("`n") -or $Text.EndsWith("`r")
    $parts = [regex]::Split($Text, "`r`n|`n|`r")
    if ($terminalNewline -and $parts.Count -gt 0 -and $parts[$parts.Count - 1] -eq "") {
        $parts = @($parts[0..($parts.Count - 2)])
    }
    return [pscustomobject]@{
        Lines = @($parts)
        Newline = $newline
        TerminalNewline = $terminalNewline
    }
}

function ConvertTo-TomlBasicString([string]$Value) {
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    $escaped = $escaped.Replace("`b", '\b').Replace("`t", '\t').Replace("`n", '\n').Replace("`f", '\f').Replace("`r", '\r')
    return '"' + $escaped + '"'
}

function Get-RootAssignmentKey([string]$Line) {
    $match = [regex]::Match($Line, '^\s*([A-Za-z0-9_-]+)\s*=')
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return $null
}

function Get-TomlAssignmentEqualsIndex([string]$Line) {
    $quote = [char]0
    $escaped = $false
    for ($index = 0; $index -lt $Line.Length; $index++) {
        $character = $Line[$index]
        if ($quote -ne [char]0) {
            if ($quote -eq '"' -and $escaped) {
                $escaped = $false
                continue
            }
            if ($quote -eq '"' -and $character -eq '\') {
                $escaped = $true
                continue
            }
            if ($character -eq $quote) { $quote = [char]0 }
            continue
        }
        if ($character -eq '#') { return -1 }
        if ($character -eq '"' -or $character -eq "'") {
            $quote = $character
            continue
        }
        if ($character -eq '=') { return $index }
    }
    return -1
}

function Test-TomlAssignmentIsSingleLine([string]$Line, [int]$EqualsIndex) {
    if ($EqualsIndex -lt 0 -or $EqualsIndex -ge ($Line.Length - 1)) { return $false }
    $quote = [char]0
    $escaped = $false
    $squareDepth = 0
    $curlyDepth = 0
    $sawValue = $false
    for ($index = $EqualsIndex + 1; $index -lt $Line.Length; $index++) {
        $character = $Line[$index]
        if ($quote -ne [char]0) {
            if ($quote -eq '"' -and $escaped) {
                $escaped = $false
                continue
            }
            if ($quote -eq '"' -and $character -eq '\') {
                $escaped = $true
                continue
            }
            if ($character -eq $quote) { $quote = [char]0 }
            continue
        }
        if ($character -eq '#') { break }
        if ([char]::IsWhiteSpace($character)) { continue }
        $sawValue = $true
        if ($character -eq '"' -or $character -eq "'") {
            if ($index + 2 -lt $Line.Length -and
                $Line[$index + 1] -eq $character -and $Line[$index + 2] -eq $character) {
                return $false
            }
            $quote = $character
            continue
        }
        switch ($character) {
            '[' { $squareDepth++; continue }
            ']' { $squareDepth--; if ($squareDepth -lt 0) { return $false }; continue }
            '{' { $curlyDepth++; continue }
            '}' { $curlyDepth--; if ($curlyDepth -lt 0) { return $false }; continue }
        }
    }
    return $sawValue -and $quote -eq [char]0 -and -not $escaped -and
        $squareDepth -eq 0 -and $curlyDepth -eq 0
}

function Assert-TomlRewriteInputSafe([string]$Text) {
    $split = Split-ConfigLines $Text
    $currentTable = $null
    foreach ($line in $split.Lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        if (Test-IsAnyTomlHeader $line) {
            $currentTable = Get-TomlTableName $line
            if ($null -eq $currentTable) {
                throw "Unsupported TOML table header; refusing a potentially lossy rewrite."
            }
            $providerComparable = $currentTable.Replace('"model_providers"', 'model_providers').Replace("'model_providers'", 'model_providers')
            if ($providerComparable.StartsWith('model_providers', [StringComparison]::Ordinal) -and
                ($line.TrimStart().StartsWith('[[') -or
                 -not [regex]::IsMatch($currentTable, '^model_providers(?:\.[A-Za-z0-9_-]+)*$'))) {
                throw "Ambiguous model_providers table names are not supported by the safe lightweight rewrite."
            }
            continue
        }

        $equalsIndex = Get-TomlAssignmentEqualsIndex $line
        if ($equalsIndex -lt 0 -or -not (Test-TomlAssignmentIsSingleLine $line $equalsIndex)) {
            throw "Multiline or ambiguous TOML values are not supported by the safe lightweight rewrite."
        }
        $left = $line.Substring(0, $equalsIndex).Trim()
        if ($null -eq $currentTable -and
            [regex]::IsMatch($left, '^(?:model_providers|["'']model_providers["'']|["'']model_provider["''])$')) {
            throw "Inline or quoted root provider selectors are not supported by the safe rewrite."
        }
        $providerLeft = $left.Replace('"model_providers"', 'model_providers').Replace("'model_providers'", 'model_providers')
        if ([regex]::IsMatch($providerLeft, '^model_providers\s*\.\s*(?:custom|third_party|"custom"|''custom''|"third_party"|''third_party'')(?:\s*\.|\s*$)')) {
            throw "Dotted inline custom/third_party provider definitions are not supported by the safe rewrite."
        }
        if ($currentTable -eq 'model_providers' -and
            [regex]::IsMatch($left, '^(?:custom|third_party|"custom"|''custom''|"third_party"|''third_party'')\s*$')) {
            throw "Inline custom/third_party values inside [model_providers] are not supported by the safe rewrite."
        }
    }
}

function Remove-BlankEdges([object[]]$Lines) {
    $start = 0
    $end = $Lines.Count
    while ($start -lt $end -and [string]::IsNullOrWhiteSpace([string]$Lines[$start])) {
        $start++
    }
    while ($end -gt $start -and [string]::IsNullOrWhiteSpace([string]$Lines[$end - 1])) {
        $end--
    }
    if ($start -ge $end) {
        return @()
    }
    return @($Lines[$start..($end - 1)])
}

function Rewrite-CodexConfig(
    [string]$Text,
    [string]$BaseUrl,
    [string]$ApiKey
) {
    # Every run installs one complete, deterministic managed config. Existing
    # config bytes are backed up by the migration flow and are never merged.
    $Text = ''
    Assert-TomlRewriteInputSafe $Text
    $split = Split-ConfigLines $Text
    $lines = @($split.Lines)
    $managedStarts = @(
        '# BEGIN CODEX THIRD-PARTY API (managed by configure-codex-third-party)',
        '# BEGIN CODEX THIRD-PARTY API (managed by configure-codex-third-party.cmd)'
    )
    $managedEnd = '# END CODEX THIRD-PARTY API'
    $outside = New-Object 'Collections.Generic.List[string]'
    $rescuedRoot = [ordered]@{}
    $rescuableRootKeys = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($key in @(
        'model',
        'review_model',
        'model_catalog_json',
        'sandbox_mode',
        'approval_policy',
        'model_reasoning_effort',
        'notify'
    )) {
        [void]$rescuableRootKeys.Add($key)
    }
    $insideManaged = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if (-not $insideManaged -and $managedStarts -contains $trimmed) {
            $insideManaged = $true
            continue
        }
        if ($insideManaged) {
            if ($trimmed -eq $managedEnd) {
                $insideManaged = $false
                continue
            }
            if ($managedStarts -contains $trimmed) {
                throw "Nested managed config marker was found."
            }
            if (-not (Test-IsAnyTomlHeader $line)) {
                $key = Get-RootAssignmentKey $line
                if ($null -ne $key -and $rescuableRootKeys.Contains($key) -and
                    -not $rescuedRoot.Contains($key)) {
                    # Older patch revisions sometimes placed these root-only
                    # settings after a provider header. They are rescued from
                    # anywhere in the managed block, then emitted before the
                    # first TOML table. Values outside the block still win.
                    $rescuedRoot[$key] = $line
                }
            }
            continue
        }
        if ($trimmed -eq $managedEnd) {
            throw "A managed config END marker has no matching BEGIN marker."
        }
        $outside.Add($line)
    }
    if ($insideManaged) {
        throw "The existing managed config block has no END marker."
    }

    # Remove every custom/third_party table and descendant, but preserve MCP,
    # plugins, projects, other providers, and the optional [model_providers]
    # parent table.
    $cleaned = New-Object 'Collections.Generic.List[string]'
    $skipTable = $false
    foreach ($line in $outside) {
        if (Test-IsAnyTomlHeader $line) {
            $name = Get-TomlTableName $line
            $skipTable = $name -eq 'model_providers.custom' -or
                $name.StartsWith('model_providers.custom.', [StringComparison]::Ordinal) -or
                $name -eq 'model_providers.third_party' -or
                $name.StartsWith('model_providers.third_party.', [StringComparison]::Ordinal)
        }
        if (-not $skipTable) {
            $cleaned.Add($line)
        }
    }

    $firstTable = $cleaned.Count
    for ($index = 0; $index -lt $cleaned.Count; $index++) {
        if (Test-IsAnyTomlHeader $cleaned[$index]) {
            $firstTable = $index
            break
        }
    }
    $root = New-Object 'Collections.Generic.List[string]'
    $tables = New-Object 'Collections.Generic.List[string]'
    for ($index = 0; $index -lt $cleaned.Count; $index++) {
        if ($index -lt $firstTable) { $root.Add($cleaned[$index]) } else { $tables.Add($cleaned[$index]) }
    }

    $existingRootKeys = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($line in $root) {
        $key = Get-RootAssignmentKey $line
        if ($null -ne $key) { [void]$existingRootKeys.Add($key) }
    }
    foreach ($key in $rescuedRoot.Keys) {
        if (-not $existingRootKeys.Contains($key)) {
            $root.Add($rescuedRoot[$key])
            [void]$existingRootKeys.Add($key)
        }
    }

    # The lightweight workflow has a deliberately predictable starter
    # experience: the configured default model with xhigh reasoning. These must be root keys;
    # putting either below a TOML table silently changes its meaning.
    $normalizedRoot = New-Object 'Collections.Generic.List[string]'
    $providerWritten = $false
    $modelWritten = $false
    $reasoningEffortWritten = $false
    foreach ($line in $root) {
        $key = Get-RootAssignmentKey $line
        if ($key -eq 'model_provider') {
            if (-not $providerWritten) {
                $normalizedRoot.Add('model_provider = "custom"')
                $providerWritten = $true
            }
            continue
        }
        if ($key -eq 'model') {
            if (-not $modelWritten) {
                $normalizedRoot.Add(('model = ' + (ConvertTo-TomlBasicString $managedDefaultModel)))
                $modelWritten = $true
            }
            continue
        }
        if ($key -eq 'model_reasoning_effort') {
            if (-not $reasoningEffortWritten) {
                $normalizedRoot.Add(('model_reasoning_effort = ' + (ConvertTo-TomlBasicString $managedReasoningEffort)))
                $reasoningEffortWritten = $true
            }
            continue
        }
        $normalizedRoot.Add($line)
    }
    if (-not $providerWritten) {
        $insertion = 0
        while ($insertion -lt $normalizedRoot.Count) {
            $value = $normalizedRoot[$insertion].Trim()
            if ($value -ne '' -and -not $value.StartsWith('#')) { break }
            $insertion++
        }
        $normalizedRoot.Insert($insertion, 'model_provider = "custom"')
    }
    if (-not $modelWritten) {
        $normalizedRoot.Insert(1, ('model = ' + (ConvertTo-TomlBasicString $managedDefaultModel)))
    }
    if (-not $reasoningEffortWritten) {
        $normalizedRoot.Insert(2, ('model_reasoning_effort = ' + (ConvertTo-TomlBasicString $managedReasoningEffort)))
    }

    $rootArray = Remove-BlankEdges @($normalizedRoot)
    $tableArray = @($tables)
    $parentIndices = New-Object 'Collections.Generic.List[int]'
    for ($index = 0; $index -lt $tableArray.Count; $index++) {
        if ((Get-TomlTableName $tableArray[$index]) -eq 'model_providers') {
            $parentIndices.Add($index)
        }
    }
    if ($parentIndices.Count -gt 1) {
        throw "Multiple [model_providers] parent tables were found; refusing a lossy rewrite."
    }

    $customInsertion = 0
    if ($parentIndices.Count -eq 1) {
        $customInsertion = $tableArray.Count
        for ($index = $parentIndices[0] + 1; $index -lt $tableArray.Count; $index++) {
            if (Test-IsAnyTomlHeader $tableArray[$index]) {
                $customInsertion = $index
                break
            }
        }
    }
    else {
        $customInsertion = 0
        for ($index = 0; $index -lt $tableArray.Count; $index++) {
            $name = Get-TomlTableName $tableArray[$index]
            if ($null -ne $name -and
                ($name -eq 'model_providers' -or $name.StartsWith('model_providers.', [StringComparison]::Ordinal))) {
                $customInsertion = $index
                break
            }
            if (Test-IsAnyTomlHeader $tableArray[$index]) {
                # Put custom before the first unrelated table when no provider
                # parent/child is present.
                $customInsertion = $index
                break
            }
        }
    }

    $customTable = @(
        '[model_providers.custom]',
        'name = "custom"',
        ('base_url = ' + (ConvertTo-TomlBasicString $BaseUrl)),
        'wire_api = "responses"',
        ('experimental_bearer_token = ' + (ConvertTo-TomlBasicString $ApiKey)),
        'requires_openai_auth = false',
        'supports_websockets = false'
    )

    $beforeTables = if ($customInsertion -gt 0) { @($tableArray[0..($customInsertion - 1)]) } else { @() }
    $afterTables = if ($customInsertion -lt $tableArray.Count) { @($tableArray[$customInsertion..($tableArray.Count - 1)]) } else { @() }
    $output = New-Object 'Collections.Generic.List[string]'
    foreach ($line in $rootArray) { $output.Add($line) }
    if ($output.Count -gt 0 -and $output[$output.Count - 1].Trim() -ne '') { $output.Add('') }
    foreach ($line in (Remove-BlankEdges $beforeTables)) { $output.Add($line) }
    if ($output.Count -gt 0 -and $output[$output.Count - 1].Trim() -ne '') { $output.Add('') }
    foreach ($line in $customTable) { $output.Add($line) }
    $trimmedAfter = Remove-BlankEdges $afterTables
    if ($trimmedAfter.Count -gt 0) {
        $output.Add('')
        foreach ($line in $trimmedAfter) { $output.Add($line) }
    }

    $result = [string]::Join("`r`n", @($output)) + "`r`n"
    Assert-ManagedConfigShape $result $BaseUrl $ApiKey
    return $result
}

function Get-TomlSectionLines([string]$Text, [string]$TableName) {
    $split = Split-ConfigLines $Text
    $found = New-Object 'Collections.Generic.List[object]'
    $current = $null
    foreach ($line in $split.Lines) {
        if (Test-IsAnyTomlHeader $line) {
            $current = Get-TomlTableName $line
            if ($current -eq $TableName) {
                $found.Add((New-Object 'Collections.Generic.List[string]'))
            }
            continue
        }
        if ($current -eq $TableName) {
            $found[$found.Count - 1].Add($line)
        }
    }
    # PowerShell 5.1 has a binder defect when a List[object] containing
    # generic lists is wrapped with @(...): it throws "Argument types do not
    # match". Emit each section as one non-enumerated pipeline object instead.
    foreach ($section in $found) {
        Write-Output -NoEnumerate $section
    }
}

function Assert-ManagedConfigShape([string]$Text, [string]$BaseUrl, [string]$ApiKey) {
    Assert-TomlRewriteInputSafe $Text
    $split = Split-ConfigLines $Text
    $rootProviderCount = 0
    $rootModelCount = 0
    $rootReasoningEffortCount = 0
    $rootModelValid = $false
    $rootReasoningEffortValid = $false
    $customCount = 0
    $thirdPartyCount = 0
    $reachedTable = $false
    foreach ($line in $split.Lines) {
        if (Test-IsAnyTomlHeader $line) {
            $reachedTable = $true
            $name = Get-TomlTableName $line
            if ($name -eq 'model_providers.custom') { $customCount++ }
            if ($name -eq 'model_providers.third_party' -or
                ($null -ne $name -and $name.StartsWith('model_providers.third_party.', [StringComparison]::Ordinal))) {
                $thirdPartyCount++
            }
            continue
        }
        if (-not $reachedTable) {
            $key = Get-RootAssignmentKey $line
            if ($key -eq 'model_provider') {
                $rootProviderCount++
                if ($line -match '^\s*model_provider\s*=\s*"custom"\s*(?:#.*)?$') { $rootProviderValid = $true }
            }
            elseif ($key -eq 'model') {
                $rootModelCount++
                if ($line -match ('^\s*model\s*=\s*' + [regex]::Escape((ConvertTo-TomlBasicString $managedDefaultModel)) + '\s*(?:#.*)?$')) {
                    $rootModelValid = $true
                }
            }
            elseif ($key -eq 'model_reasoning_effort') {
                $rootReasoningEffortCount++
                if ($line -match ('^\s*model_reasoning_effort\s*=\s*' + [regex]::Escape((ConvertTo-TomlBasicString $managedReasoningEffort)) + '\s*(?:#.*)?$')) {
                    $rootReasoningEffortValid = $true
                }
            }
        }
    }
    if ($rootProviderCount -ne 1 -or -not $rootProviderValid) { throw "Rewritten config must select root model_provider=custom exactly once." }
    if ($rootModelCount -ne 1 -or -not $rootModelValid) { throw "Rewritten config must set root model=$managedDefaultModel exactly once." }
    if ($rootReasoningEffortCount -ne 1 -or -not $rootReasoningEffortValid) { throw "Rewritten config must set root model_reasoning_effort=$managedReasoningEffort exactly once." }
    if ($customCount -ne 1) { throw "Rewritten config must contain exactly one [model_providers.custom] table." }
    if ($thirdPartyCount -ne 0) { throw "Legacy model_providers.third_party was not fully removed." }
    if ([regex]::IsMatch($Text, '(?im)^\s*env_key\s*=')) {
        throw "The final config still contains legacy env_key authentication."
    }
    $sections = @(Get-TomlSectionLines $Text 'model_providers.custom')
    if ($sections.Count -ne 1) { throw "Could not validate the custom provider table." }
    $body = [string]::Join("`n", @($sections[0]))
    $expectedLines = @(
        '^\s*name\s*=\s*"custom"\s*(?:#.*)?$',
        ('^\s*base_url\s*=\s*' + [regex]::Escape((ConvertTo-TomlBasicString $BaseUrl)) + '\s*(?:#.*)?$'),
        '^\s*wire_api\s*=\s*"responses"\s*(?:#.*)?$',
        ('^\s*experimental_bearer_token\s*=\s*' + [regex]::Escape((ConvertTo-TomlBasicString $ApiKey)) + '\s*(?:#.*)?$'),
        '^\s*requires_openai_auth\s*=\s*false\s*(?:#.*)?$',
        '^\s*supports_websockets\s*=\s*false\s*(?:#.*)?$'
    )
    foreach ($pattern in $expectedLines) {
        if (-not [regex]::IsMatch($body, $pattern, [Text.RegularExpressions.RegexOptions]::Multiline)) {
            throw "The rewritten custom provider failed a required field check."
        }
    }
}

function ConvertFrom-TomlStringLiteral([string]$Rendered, [string]$KeyName) {
    $value = $Rendered.Trim()
    if ($value.StartsWith("'")) {
        $closing = $value.IndexOf("'", 1)
        if ($closing -lt 0) { throw "Unterminated TOML string for $KeyName." }
        $tail = $value.Substring($closing + 1).Trim()
        if ($tail -ne '' -and -not $tail.StartsWith('#')) { throw "Unexpected TOML text after $KeyName." }
        return $value.Substring(1, $closing - 1)
    }
    if (-not $value.StartsWith('"')) {
        throw "$KeyName must be a single-line TOML string."
    }

    $builder = New-Object Text.StringBuilder
    $index = 1
    $closed = $false
    while ($index -lt $value.Length) {
        $character = $value[$index]
        if ($character -eq '"') {
            $closed = $true
            $index++
            break
        }
        if ($character -ne '\') {
            [void]$builder.Append($character)
            $index++
            continue
        }
        $index++
        if ($index -ge $value.Length) { throw "Unterminated TOML escape for $KeyName." }
        $escape = $value[$index]
        switch ($escape) {
            'b' { [void]$builder.Append("`b"); $index++ }
            't' { [void]$builder.Append("`t"); $index++ }
            'n' { [void]$builder.Append("`n"); $index++ }
            'f' { [void]$builder.Append("`f"); $index++ }
            'r' { [void]$builder.Append("`r"); $index++ }
            '"' { [void]$builder.Append('"'); $index++ }
            '\' { [void]$builder.Append('\'); $index++ }
            'u' {
                if ($index + 4 -ge $value.Length) { throw "Invalid TOML Unicode escape for $KeyName." }
                $hex = $value.Substring($index + 1, 4)
                $code = 0
                if (-not [int]::TryParse($hex, [Globalization.NumberStyles]::HexNumber, [Globalization.CultureInfo]::InvariantCulture, [ref]$code)) {
                    throw "Invalid TOML Unicode escape for $KeyName."
                }
                [void]$builder.Append([char]$code)
                $index += 5
            }
            'U' {
                if ($index + 8 -ge $value.Length) { throw "Invalid TOML Unicode escape for $KeyName." }
                $hex = $value.Substring($index + 1, 8)
                $code = 0
                if (-not [int]::TryParse($hex, [Globalization.NumberStyles]::HexNumber, [Globalization.CultureInfo]::InvariantCulture, [ref]$code)) {
                    throw "Invalid TOML Unicode escape for $KeyName."
                }
                [void]$builder.Append([char]::ConvertFromUtf32($code))
                $index += 9
            }
            default { throw "Unsupported TOML escape for $KeyName." }
        }
    }
    if (-not $closed) { throw "Unterminated TOML string for $KeyName." }
    $tail = $value.Substring($index).Trim()
    if ($tail -ne '' -and -not $tail.StartsWith('#')) { throw "Unexpected TOML text after $KeyName." }
    return $builder.ToString()
}

function Get-RootTomlString([string]$Text, [string]$KeyName) {
    $split = Split-ConfigLines $Text
    $renderedValues = New-Object 'Collections.Generic.List[string]'
    foreach ($line in $split.Lines) {
        if (Test-IsAnyTomlHeader $line) { break }
        $match = [regex]::Match($line, ('^\s*' + [regex]::Escape($KeyName) + '\s*=\s*(.+)$'))
        if ($match.Success) { $renderedValues.Add($match.Groups[1].Value) }
    }
    if ($renderedValues.Count -gt 1) { throw "Root key $KeyName is declared more than once." }
    if ($renderedValues.Count -eq 0) { return $null }
    return ConvertFrom-TomlStringLiteral $renderedValues[0] $KeyName
}

function Get-ExternalSqliteHome([string]$ConfigText, [string]$CodexDataHome) {
    $configured = Get-RootTomlString $ConfigText 'sqlite_home'
    $raw = if (-not [string]::IsNullOrWhiteSpace($configured)) {
        $configured
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_SQLITE_HOME)) {
        $env:CODEX_SQLITE_HOME
    }
    else {
        return $null
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($raw.Trim())
    if ($expanded -eq '~') { $expanded = $env:USERPROFILE }
    elseif ($expanded.StartsWith('~\') -or $expanded.StartsWith('~/')) {
        $expanded = Join-Path $env:USERPROFILE $expanded.Substring(2)
    }
    if (-not [IO.Path]::IsPathRooted($expanded)) {
        throw "sqlite_home/CODEX_SQLITE_HOME must be an absolute path for a safe migration: $expanded"
    }
    try {
        return [IO.Path]::GetFullPath($expanded)
    }
    catch {
        throw "Could not normalize path [$Value] after expansion [$expanded]: $($_.Exception.Message)"
    }
}

function Get-ExternalSqliteHomeForForcedReplacement([string]$ConfigText, [string]$CodexDataHome) {
    try {
        return (Get-ExternalSqliteHome $ConfigText $CodexDataHome)
    }
    catch {
        Write-Diagnostic 'CONFIG' "Existing sqlite_home could not be parsed and will not block the forced config replacement: $($_.Exception.Message)"
        return (Get-ExternalSqliteHome '' $CodexDataHome)
    }
}

function New-CodexHomeCandidate([string]$CandidatePath, [string]$Source) {
    $sources = New-Object 'Collections.Generic.List[string]'
    [void]$sources.Add($Source)
    return [pscustomobject]@{
        Home = $CandidatePath
        Sources = $sources
    }
}

function Add-CodexHomeCandidate(
    [System.Collections.Generic.List[object]]$Candidates,
    [hashtable]$Seen,
    [string]$RawHome,
    [string]$Source
) {
    if ([string]::IsNullOrWhiteSpace($RawHome)) { return }
    try {
        $codexHome = Resolve-AbsolutePath $RawHome
    }
    catch {
        $resolveError = $_.Exception.Message
        # Discovery must not discard an already absolute path solely because a
        # host-specific .NET normalization call failed. Test-Path and later
        # safety checks still validate it before anything can be changed.
        if ([IO.Path]::IsPathRooted($RawHome.Trim())) {
            $codexHome = $RawHome.Trim().Trim('"')
            Write-Diagnostic 'DISCOVERY' "Path normalization fallback used for absolute candidate: $codexHome; original error: $resolveError"
        }
        else {
            Write-Warning "忽略无法解析的 CODEX_HOME 候选（$Source）：$RawHome；原因：$resolveError"
            return
        }
    }
    Write-Diagnostic 'DISCOVERY' "Candidate source [$Source] resolved to: $codexHome"
    if (-not (Test-Path -LiteralPath $codexHome -PathType Container)) {
        Write-Diagnostic 'DISCOVERY' "Candidate directory does not exist; skipped: $codexHome"
        return
    }

    $identity = $codexHome.TrimEnd('\', '/').ToLowerInvariant()
    if ($Seen.ContainsKey($identity)) {
        $existing = $Seen[$identity]
        if (-not $existing.Sources.Contains($Source)) {
            [void]$existing.Sources.Add($Source)
        }
        Write-Diagnostic 'DISCOVERY' "Candidate already registered; merged source: $codexHome"
        return
    }

    $candidate = New-CodexHomeCandidate $codexHome $Source
    $Seen[$identity] = $candidate
    [void]$Candidates.Add($candidate)
    Write-Diagnostic 'DISCOVERY' "Candidate registered: $codexHome"
}

function Add-ManagedPatchHomeCandidates(
    [System.Collections.Generic.List[object]]$Candidates,
    [hashtable]$Seen,
    [string]$SearchRoot
) {
    Write-Diagnostic 'DISCOVERY' "Checking managed-patch metadata root: $SearchRoot"
    if (-not (Test-Path -LiteralPath $SearchRoot -PathType Container)) {
        Write-Diagnostic 'DISCOVERY' "Managed-patch metadata root is absent; skipped: $SearchRoot"
        return
    }
    try {
        $directories = @(Get-ChildItem -LiteralPath $SearchRoot -Directory -Force -ErrorAction Stop)
    }
    catch {
        Write-Warning "无法读取受管补丁目录：$SearchRoot"
        return
    }

    foreach ($directory in $directories) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $marker = Join-Path $directory.FullName '.codex-gpt56-patch.json'
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { continue }
        try {
            Assert-NotReparsePoint $marker '受管补丁元数据'
            $metadata = (Read-Utf8FileStrict $marker).Text | ConvertFrom-Json -ErrorAction Stop
            $markerHome = [string]$metadata.codex_home
            if ([string]::IsNullOrWhiteSpace($markerHome)) {
                Write-Warning "受管补丁元数据未声明 codex_home，已忽略：$marker"
                continue
            }
            Write-Diagnostic 'DISCOVERY' "Managed-patch marker found: $marker; declared CODEX_HOME: $markerHome"
            Add-CodexHomeCandidate $Candidates $Seen $markerHome ("受管补丁元数据：" + $directory.FullName)
        }
        catch {
            Write-Warning "无法读取受管补丁元数据，已忽略：$marker"
        }
    }
}

function Get-CodexHomeCandidates {
    $candidates = New-Object 'Collections.Generic.List[object]'
    $seen = @{}
    Write-Diagnostic 'DISCOVERY' 'Starting automatic CODEX_HOME discovery (default home, clones, and managed patch metadata).'
    $canonicalHome = Join-Path $env:USERPROFILE '.codex'
    Add-CodexHomeCandidate $candidates $seen $canonicalHome '默认 ~/.codex'

    $cloneRoot = Join-Path $env:USERPROFILE '.codex-clones'
    if (Test-Path -LiteralPath $cloneRoot -PathType Container) {
        Write-Diagnostic 'DISCOVERY' "Enumerating clone root: $cloneRoot"
        try {
            foreach ($directory in @(Get-ChildItem -LiteralPath $cloneRoot -Directory -Force -ErrorAction Stop)) {
                if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    Write-Warning "忽略作为 CODEX_HOME 的链接目录：$($directory.FullName)"
                    continue
                }
                Add-CodexHomeCandidate $candidates $seen $directory.FullName '补丁分身 ~/.codex-clones'
            }
        }
        catch {
            Write-Warning "无法枚举补丁分身目录：$cloneRoot"
        }
    }
    else {
        Write-Diagnostic 'DISCOVERY' "Clone root is absent: $cloneRoot"
    }

    # Our managed Desktop copy records its exact CODEX_HOME in this marker.
    # This covers a custom clone location that is not beneath .codex-clones.
    Add-ManagedPatchHomeCandidates $candidates $seen (Join-Path $env:USERPROFILE 'Applications')
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Add-ManagedPatchHomeCandidates $candidates $seen (Join-Path $env:LOCALAPPDATA 'Programs')
    }

    foreach ($candidate in $candidates) {
        Write-Output -NoEnumerate $candidate
    }
    Write-Diagnostic 'DISCOVERY' "Automatic CODEX_HOME discovery completed; candidate count: $($candidates.Count)."
}

function Get-CodexHomeSessionStats($Candidate) {
    $codexHome = [string]$Candidate.Home
    $jsonlFiles = 0
    $sqliteDatabases = 0
    [int64]$sqliteThreadRows = 0
    $inspectionError = $null

    try {
        Write-Diagnostic 'DISCOVERY' "Inspecting candidate session store: $codexHome"
        if (-not (Test-Path -LiteralPath $codexHome -PathType Container)) {
            throw "目录不存在。"
        }
        $configPath = Join-Path $codexHome 'config.toml'
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            throw "缺少 config.toml。请先从对应的 Codex 启动入口正常启动一次。"
        }
        Assert-NotReparsePoint $configPath 'config.toml'
        $configRead = Read-ConfigForForcedReplacement $configPath
        Write-Diagnostic 'DISCOVERY' ("Config snapshot: {0}; bytes={1}; sha256={2}" -f `
            $configPath, $configRead.Snapshot.Length, (Get-ShortSha256 $configRead.Snapshot.Sha256))
        $jsonlFiles = @(Get-JsonlPaths $codexHome).Count
        Write-Diagnostic 'DISCOVERY' "Session JSONL discovery completed: $jsonlFiles file(s)."
        $externalSqliteHome = Get-ExternalSqliteHomeForForcedReplacement $configRead.Text $codexHome
        if ($null -eq $externalSqliteHome) {
            Write-Diagnostic 'DISCOVERY' 'No external sqlite_home is configured for this candidate.'
        }
        else {
            Write-Diagnostic 'DISCOVERY' "External sqlite_home resolved to: $externalSqliteHome"
        }
        $externalValue = if ($null -eq $externalSqliteHome) { '' } else { $externalSqliteHome }
        $databaseSeen = @{}
        $databasePaths = New-Object 'Collections.Generic.List[string]'
        foreach ($databaseCandidate in @([CodexNativeSqlite]::GetCandidateDatabasePaths($codexHome, $externalValue))) {
            if ([string]::IsNullOrWhiteSpace($databaseCandidate) -or
                -not (Test-Path -LiteralPath $databaseCandidate -PathType Leaf)) {
                continue
            }
            $databasePath = [IO.Path]::GetFullPath($databaseCandidate)
            $identity = $databasePath.ToLowerInvariant()
            if ($databaseSeen.ContainsKey($identity)) { continue }
            $databaseSeen[$identity] = $true
            Assert-NotReparsePoint $databasePath 'SQLite state database'
            [void]$databasePaths.Add($databasePath)
            Write-Diagnostic 'DISCOVERY' "SQLite candidate registered: $databasePath"
        }
        foreach ($databasePath in $databasePaths) {
            $inspection = [CodexNativeSqlite]::InspectDatabase($databasePath, $sqliteBusyTimeoutMs)
            $sqliteDatabases++
            Write-Diagnostic 'DISCOVERY' ("SQLite read-only inspection: {0}; threads_table={1}; thread_rows={2}" -f `
                $databasePath, $inspection.ThreadsTablePresent, $inspection.TotalRows)
            if ($inspection.ThreadsTablePresent) {
                $sqliteThreadRows += [int64]$inspection.TotalRows
            }
        }
    }
    catch {
        $inspectionError = $_.Exception.Message
        Write-Diagnostic 'DISCOVERY' "Candidate inspection failed: $codexHome; error: $inspectionError"
    }

    Write-Diagnostic 'DISCOVERY' ("Candidate summary: {0}; JSONL={1}; SQLite databases={2}; SQLite threads={3}; usable={4}" -f `
        $codexHome, $jsonlFiles, $sqliteDatabases, $sqliteThreadRows, ([string]::IsNullOrWhiteSpace($inspectionError)))

    return [pscustomobject]@{
        Home = $codexHome
        Sources = $Candidate.Sources
        JsonlFiles = [int]$jsonlFiles
        SqliteDatabases = [int]$sqliteDatabases
        SqliteThreadRows = [int64]$sqliteThreadRows
        HasSessionData = ($jsonlFiles -gt 0 -or $sqliteThreadRows -gt 0)
        BootstrapNoSessions = $false
        Error = $inspectionError
    }
}

function Write-CodexHomeCandidateSummary([int]$Number, $Stats) {
    $sources = @($Stats.Sources) -join '；'
    Write-Host ("  [{0}] JSONL {1} 个；SQLite 线程 {2} 条（数据库 {3} 个）" -f `
        $Number, $Stats.JsonlFiles, $Stats.SqliteThreadRows, $Stats.SqliteDatabases)
    Write-Host ("      {0}" -f $Stats.Home)
    Write-Host ("      来源：{0}" -f $sources)
    if (-not [string]::IsNullOrWhiteSpace([string]$Stats.Error)) {
        Write-Host ("      无法安全读取：{0}" -f $Stats.Error) -ForegroundColor Yellow
    }
}

function Select-CodexHomeForMigration {
    $explicitHome = $null
    $explicitSource = $null
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_LIGHTWEIGHT_CODEX_HOME)) {
        $explicitHome = Resolve-AbsolutePath $env:CODEX_LIGHTWEIGHT_CODEX_HOME
        $explicitSource = 'CODEX_LIGHTWEIGHT_CODEX_HOME'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        # Preserve an intentionally supplied CODEX_HOME, including a clone.
        # Explorer normally has no such variable, so automatic discovery below
        # handles that common double-click case.
        $explicitHome = Resolve-AbsolutePath $env:CODEX_HOME
        $explicitSource = 'CODEX_HOME'
    }

    if ($null -ne $explicitHome) {
        Write-Diagnostic 'DISCOVERY' "Using explicit CODEX_HOME source: $explicitSource; path: $explicitHome"
        $stats = Get-CodexHomeSessionStats (New-CodexHomeCandidate $explicitHome $explicitSource)
        if (-not [string]::IsNullOrWhiteSpace([string]$stats.Error)) {
            throw "指定的 $explicitSource 不能作为安全迁移目标：$($stats.Home)；$($stats.Error)"
        }
        if (-not $stats.HasSessionData) {
            $stats.BootstrapNoSessions = $true
            Write-Step "未发现已有会话，按首次安装配置模式继续：$($stats.Home)"
            Write-Diagnostic 'DISCOVERY' 'Explicit target has no existing sessions; provider configuration will be applied without a history migration.'
        }
        Write-Step "使用 $explicitSource 指定的 CODEX_HOME。"
        Write-Diagnostic 'DISCOVERY' "Explicit CODEX_HOME accepted for migration: $($stats.Home)"
        return $stats
    }

    $allStats = New-Object 'Collections.Generic.List[object]'
    foreach ($candidate in @(Get-CodexHomeCandidates)) {
        [void]$allStats.Add((Get-CodexHomeSessionStats $candidate))
    }
    if ($allStats.Count -eq 0) {
        throw "未找到可检查的 CODEX_HOME（默认 ~/.codex、~/.codex-clones 和受管补丁元数据均无有效目录）。未修改任何配置或会话。"
    }
    Write-Diagnostic 'DISCOVERY' "Candidate inspection completed; inspected stores: $($allStats.Count)."

    $eligible = New-Object 'Collections.Generic.List[object]'
    foreach ($stats in $allStats) {
        if (-not [string]::IsNullOrWhiteSpace([string]$stats.Error)) {
            Write-Warning "跳过不可安全迁移的候选目录：$($stats.Home)；$($stats.Error)"
            continue
        }
        if ($stats.HasSessionData) {
            [void]$eligible.Add($stats)
        }
    }
    Write-Diagnostic 'DISCOVERY' "Eligible session stores after safety checks: $($eligible.Count)."

    if ($eligible.Count -eq 0) {
        $bootstrapCandidates = New-Object 'Collections.Generic.List[object]'
        foreach ($stats in $allStats) {
            if ([string]::IsNullOrWhiteSpace([string]$stats.Error)) {
                [void]$bootstrapCandidates.Add($stats)
            }
        }
        if ($bootstrapCandidates.Count -eq 1) {
            $bootstrap = $bootstrapCandidates[0]
            $bootstrap.BootstrapNoSessions = $true
            Write-Step ("未发现历史会话，识别为首次安装配置：{0}" -f $bootstrap.Home)
            Write-Diagnostic 'DISCOVERY' 'Exactly one safe empty CODEX_HOME was found; continuing in first-install configuration mode without a session migration.'
            return $bootstrap
        }
        Write-Host ''
        Write-Host '已检查的 CODEX_HOME 候选：' -ForegroundColor Yellow
        $number = 1
        foreach ($stats in $allStats) {
            Write-CodexHomeCandidateSummary $number $stats
            $number++
        }
        throw "未发现包含会话的 CODEX_HOME（JSONL=0 且 SQLite threads=0）。为避免把空目录配置成成功，脚本未修改任何配置或会话。请从要迁移的 Codex 启动入口运行一次后重试；也可将实际 CODEX_HOME 文件夹直接拖到此 BAT 上再运行。"
    }

    if ($eligible.Count -eq 1) {
        $selected = $eligible[0]
        Write-Step ("已自动识别含会话的 CODEX_HOME：{0}（JSONL {1}，SQLite threads {2}）" -f `
            $selected.Home, $selected.JsonlFiles, $selected.SqliteThreadRows)
        Write-Diagnostic 'DISCOVERY' "Automatic selection accepted: $($selected.Home)"
        return $selected
    }

    Write-Host ''
    Write-Host '检测到多个含会话的 CODEX_HOME。请选择本次要统一到 custom 的一个目录：' -ForegroundColor Cyan
    for ($index = 0; $index -lt $eligible.Count; $index++) {
        Write-CodexHomeCandidateSummary ($index + 1) $eligible[$index]
    }
    $choice = (Read-Host '输入序号；其他输入取消').Trim()
    $selectedIndex = 0
    if (-not [int]::TryParse($choice, [ref]$selectedIndex) -or
        $selectedIndex -lt 1 -or $selectedIndex -gt $eligible.Count) {
        throw "未选择有效 CODEX_HOME，已取消且未修改任何配置或会话。"
    }
    Write-Diagnostic 'DISCOVERY' "User selected candidate index ${selectedIndex}: $($eligible[$selectedIndex - 1].Home)"
    return $eligible[$selectedIndex - 1]
}

function Get-RunningConversationProcesses {
    return @(
        Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -in @('Codex', 'ChatGPT')
        }
    )
}

function Get-RunningCcSwitchProcesses {
    return @(
        Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -in @('CCSwitch', 'cc-switch', 'cc_switch')
        }
    )
}

function Wait-ForConversationApps {
    $lastNotice = [DateTime]::MinValue
    Write-Diagnostic 'PROCESS' 'Checking whether Codex/ChatGPT has exited before any write operation.'
    while ($true) {
        $running = @(Get-RunningConversationProcesses)
        if ($running.Count -eq 0) {
            Start-Sleep -Milliseconds 750
            Write-Diagnostic 'PROCESS' 'Codex/ChatGPT exit check passed.'
            return
        }
        if (([DateTime]::UtcNow - $lastNotice).TotalSeconds -ge 15) {
            $names = @($running.ProcessName | Sort-Object -Unique)
            Write-Step "正在等待 Codex/ChatGPT 正常退出：$($names -join ', ')；脚本不会强制结束进程。"
            Write-Diagnostic 'PROCESS' "Waiting process details: $((@($running | ForEach-Object { $_.ProcessName + '#' + $_.Id }) -join ', '))"
            $lastNotice = [DateTime]::UtcNow
        }
        Start-Sleep -Milliseconds 500
    }
}

function Assert-ConversationAppsRemainClosed {
    $running = @(Get-RunningConversationProcesses)
    if ($running.Count -gt 0) {
        $names = @($running.ProcessName | Sort-Object -Unique)
        Write-Diagnostic 'PROCESS' "Write guard failed because a conversation app is running: $((@($running | ForEach-Object { $_.ProcessName + '#' + $_.Id }) -join ', '))"
        throw "Codex/ChatGPT was started again during migration: $($names -join ', ')."
    }
}

function Get-JsonlPaths([string]$CodexDataHome) {
    $result = New-Object 'Collections.Generic.List[string]'
    foreach ($name in @('sessions', 'archived_sessions')) {
        $root = Join-Path $CodexDataHome $name
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $rootItem = Get-Item -LiteralPath $root -Force
        if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Session directory must not be a junction/symlink: $root"
        }
        $pending = New-Object 'Collections.Generic.Stack[string]'
        $pending.Push($rootItem.FullName)
        while ($pending.Count -gt 0) {
            $directory = $pending.Pop()
            foreach ($item in (Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
                if (($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        throw "Session tree contains a junction/symlink: $($item.FullName)"
                    }
                    $pending.Push($item.FullName)
                }
                elseif ($item.Extension.Equals('.jsonl', [StringComparison]::OrdinalIgnoreCase)) {
                    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        throw "Session rollout must not be a symlink: $($item.FullName)"
                    }
                    $result.Add($item.FullName)
                }
            }
        }
    }
    return @($result | Sort-Object)
}

function Assert-NoIncompleteRunLedger([string]$CodexDataHome) {
    $root = Join-Path $CodexDataHome 'backups\codex-gpt56\lightweight-native'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return }

    $expectedIdentity = Get-Sha256HexFromText ([IO.Path]::GetFullPath($CodexDataHome).ToLowerInvariant())
    foreach ($directory in (Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction Stop)) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "A migration ledger directory must not be a reparse point: $($directory.FullName)"
        }
        $manifestPath = Join-Path $directory.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "An unfinished migration directory has no manifest; inspect it before retrying: $($directory.FullName)"
        }
        try {
            $manifestRead = Read-Utf8FileStrict $manifestPath
            $manifest = $manifestRead.Text | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "A previous migration manifest cannot be validated; refusing a new write: $manifestPath"
        }
        if ([string]$manifest.format -ne $migrationFormat -or
            [string]$manifest.codex_home_identity -ne $expectedIdentity) {
            throw "An unknown or foreign migration ledger exists in the managed ledger directory: $manifestPath"
        }
        $status = [string]$manifest.status
        if ($status -notin @('complete', 'rolled_back')) {
            throw "A previous migration is incomplete (status=$status). Refusing to overwrite evidence: $manifestPath"
        }
    }
}

function New-RunLedger([string]$CodexDataHome, [string]$BaseUrl) {
    $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
    $identity = Get-Sha256HexFromText ([IO.Path]::GetFullPath($CodexDataHome).ToLowerInvariant())
    $root = Join-Path $CodexDataHome 'backups\codex-gpt56\lightweight-native'
    $path = Join-Path $root ("{0}-{1}-{2}" -f $stamp, $identity.Substring(0, 12), [Guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $path -ErrorAction Stop)
    [void](New-Item -ItemType Directory -Path (Join-Path $path 'data') -ErrorAction Stop)
    $manifest = [ordered]@{
        format = $migrationFormat
        created_at = [DateTime]::UtcNow.ToString('o')
        codex_home = [IO.Path]::GetFullPath($CodexDataHome)
        codex_home_identity = $identity
        target_provider = $targetProvider
        base_url = $BaseUrl
        status = 'building'
        entries = @()
        summary = [ordered]@{
            jsonl_files_scanned = 0
            jsonl_files_changed = 0
            session_meta_lines_changed = 0
            sqlite_databases_scanned = 0
            sqlite_rows_changed = 0
        }
    }
    $context = [pscustomobject]@{
        Path = $path
        DataPath = Join-Path $path 'data'
        ManifestPath = Join-Path $path 'manifest.json'
        Manifest = $manifest
    }
    Write-RunManifest $context
    Write-Diagnostic 'LEDGER' "Created migration ledger: $($context.Path)"
    Write-Diagnostic 'LEDGER' "Manifest initialized: $($context.ManifestPath)"
    return $context
}

function Write-RunManifest($Ledger) {
    $json = ($Ledger.Manifest | ConvertTo-Json -Depth 12) + "`r`n"
    Write-AtomicTextFile $Ledger.ManifestPath $json
}

function Add-LedgerEntry($Ledger, [Collections.IDictionary]$Entry) {
    # Keep the original OrderedDictionary reference. Binding it to [hashtable]
    # may create a converted copy, after which later status changes are absent
    # from Ledger.Manifest.entries and rollback silently skips the artifact.
    $Ledger.Manifest.entries += ,$Entry
    Write-RunManifest $Ledger
    Write-Diagnostic 'LEDGER' "Entry recorded: kind=$($Entry.kind); status=$($Entry.status); source=$($Entry.source); backup=$($Entry.backup)"
}

function Set-LedgerStatus($Ledger, [string]$Status, [string]$ErrorMessage) {
    $Ledger.Manifest.status = $Status
    if ($Status -eq 'complete') {
        $Ledger.Manifest.completed_at = [DateTime]::UtcNow.ToString('o')
    }
    elseif ($Status -in @('rolled_back', 'rollback_failed')) {
        $Ledger.Manifest.rolled_back_at = [DateTime]::UtcNow.ToString('o')
        $Ledger.Manifest.error = $ErrorMessage
    }
    Write-RunManifest $Ledger
    Write-Diagnostic 'LEDGER' "Ledger status written: $Status"
}

function Get-BackupPath($Ledger, [string]$Kind, [string]$SourcePath) {
    $digest = Get-Sha256HexFromText ([IO.Path]::GetFullPath($SourcePath).ToLowerInvariant())
    $directory = Join-Path $Ledger.DataPath (Join-Path $Kind $digest.Substring(0, 16))
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    $backupPath = Join-Path $directory ([IO.Path]::GetFileName($SourcePath))
    Write-Diagnostic 'BACKUP' "Reserved backup path: kind=$Kind; source=$SourcePath; backup=$backupPath"
    return $backupPath
}

function Invoke-RunRollback($Ledger, [string]$Cause) {
    Write-Diagnostic 'ROLLBACK' "Rollback started. Cause: $Cause"
    $errors = New-Object 'Collections.Generic.List[string]'
    $entries = @($Ledger.Manifest.entries)
    [Array]::Reverse($entries)
    foreach ($entry in $entries) {
        if ($entry.status -notin @('changing', 'changed')) { continue }
        try {
            Write-Diagnostic 'ROLLBACK' "Evaluating entry: kind=$($entry.kind); status=$($entry.status); source=$($entry.source)"
            if ($entry.kind -eq 'jsonl') {
                $currentHash = [CodexLightweight.JsonlMigration]::ComputeFileSha256([string]$entry.source)
                if ($currentHash -eq [string]$entry.before_sha256) {
                    # Apply did not replace the source, or its native rollback succeeded.
                    Write-Diagnostic 'ROLLBACK' "JSONL already matches pre-migration bytes: $($entry.source)"
                }
                elseif ($currentHash -eq [string]$entry.after_sha256) {
                    Write-Diagnostic 'ROLLBACK' "Restoring JSONL from verified backup: $($entry.backup)"
                    [CodexLightweight.JsonlMigration]::RestoreBackup(
                        [string]$entry.source,
                        [string]$entry.backup,
                        [string]$entry.after_sha256,
                        [string]$entry.before_sha256
                    )
                }
                else {
                    throw "JSONL changed after the migration write; automatic restore was skipped."
                }
            }
            elseif ($entry.kind -eq 'sqlite') {
                $backupExists = Test-Path -LiteralPath ([string]$entry.backup) -PathType Leaf
                $matchesBackup = $false
                if ($backupExists) {
                    if ($entry.Contains('backup_sha256') -and
                        (Get-FileSnapshot ([string]$entry.backup)).Sha256 -ne [string]$entry.backup_sha256) {
                        throw "SQLite backup hash is invalid; automatic restore was skipped."
                    }
                    $matchesBackup = [CodexNativeSqlite]::HaveExactThreadsState(
                        [string]$entry.source,
                        [string]$entry.backup,
                        $sqliteBusyTimeoutMs
                    )
                }
                if (-not $backupExists -and $entry.status -eq 'changing') {
                    # The native implementation creates its verified backup
                    # before UPDATE, so it cannot have mutated without one.
                    Write-Diagnostic 'ROLLBACK' "SQLite has no verified backup and was not committed; no restore required: $($entry.source)"
                }
                elseif ($matchesBackup) {
                    # The native transaction rolled back or never updated.
                    Write-Diagnostic 'ROLLBACK' "SQLite already matches verified pre-migration state: $($entry.source)"
                }
                elseif ($entry.status -eq 'changed' -or
                    ($entry.Contains('expected_total_rows') -and
                     $entry.Contains('expected_thread_ids_sha256') -and
                     $entry.Contains('expected_after_non_provider_sha256') -and
                     $entry.Contains('expected_after_full_state_sha256') -and
                     $entry.Contains('before_full_state_sha256'))) {
                    $safetyRoot = Join-Path $Ledger.DataPath 'rollback-safety'
                    $safetyPath = Join-Path $safetyRoot ((Get-Sha256HexFromText ([string]$entry.source)).Substring(0, 16) + '.sqlite')
                    $safetyParent = Split-Path -Parent $safetyPath
                    if (-not (Test-Path -LiteralPath $safetyParent -PathType Container)) {
                        [void](New-Item -ItemType Directory -Path $safetyParent -Force)
                    }
                    [CodexNativeSqlite]::RestoreDatabase(
                        [string]$entry.backup,
                        [string]$entry.source,
                        $safetyPath,
                        $sqliteBusyTimeoutMs,
                        [int64]$entry.expected_total_rows,
                        [string]$entry.expected_thread_ids_sha256,
                        [string]$entry.expected_after_non_provider_sha256,
                        [string]$entry.expected_after_full_state_sha256,
                        [string]$entry.before_full_state_sha256
                    ) | Out-Null
                    Write-Diagnostic 'ROLLBACK' "SQLite restored from verified backup: $($entry.source)"
                }
                else {
                    throw "SQLite outcome is indeterminate while its ledger entry is changing; preserving source and backup for review."
                }
            }
            elseif ($entry.kind -eq 'config') {
                $current = Get-FileSnapshot ([string]$entry.source)
                if ($current.Sha256 -eq [string]$entry.before_sha256) {
                    # Atomic replacement did not happen.
                    Write-Diagnostic 'ROLLBACK' "Config already matches pre-migration bytes: $($entry.source)"
                }
                elseif ($current.Sha256 -ne [string]$entry.after_sha256) {
                    throw "Config changed after this script wrote it; automatic restore was skipped to preserve the newer CC Switch/user edit."
                }
                else {
                    $beforeBytes = [IO.File]::ReadAllBytes([string]$entry.backup)
                    if ((Get-Sha256HexFromBytes $beforeBytes) -ne [string]$entry.before_sha256) {
                        throw "Config backup hash is invalid; automatic restore was skipped."
                    }
                    Write-FileAtomic ([string]$entry.source) $beforeBytes $current
                    Write-Diagnostic 'ROLLBACK' "Config restored from verified backup: $($entry.source)"
                }
            }
            $entry.status = 'rolled_back'
            Write-RunManifest $Ledger
            Write-Diagnostic 'ROLLBACK' "Entry marked rolled_back: $($entry.source)"
        }
        catch {
            $errors.Add("$($entry.source): $($_.Exception.Message)")
            Write-Diagnostic 'ROLLBACK' "Rollback error for $($entry.source): $($_.Exception.Message)"
        }
    }
    if ($errors.Count -eq 0) {
        Set-LedgerStatus $Ledger 'rolled_back' $Cause
        Write-Diagnostic 'ROLLBACK' 'Rollback completed successfully.'
        return
    }
    Set-LedgerStatus $Ledger 'rollback_failed' ($Cause + '; rollback: ' + ($errors -join '; '))
    Write-Diagnostic 'ROLLBACK' "Rollback completed with $($errors.Count) error(s)."
    throw "Migration failed and automatic rollback was incomplete: $($errors -join '; ')"
}

function Invoke-LightweightNativeMigration(
    [string]$CodexDataHome,
    [string]$ConfigPath,
    [string]$BaseUrl,
    [string]$ApiKey
) {
    if ($null -eq ('CodexLightweight.JsonlMigration' -as [type])) {
        throw "Embedded JSONL migration component was not loaded."
    }
    if ($null -eq ('CodexNativeSqlite' -as [type])) {
        throw "Embedded SQLite migration component was not loaded."
    }

    Write-Diagnostic 'MIGRATION' "Migration entry: CODEX_HOME=$CodexDataHome; config=$ConfigPath; target_provider=$targetProvider"

    $lockRoot = Join-Path $CodexDataHome 'backups\codex-gpt56\lightweight-native'
    [void](New-Item -ItemType Directory -Path $lockRoot -Force -ErrorAction Stop)
    $lockPath = Join-Path $lockRoot '.migration.lock'
    try {
        $runLock = New-Object IO.FileStream(
            $lockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    }
    catch {
        throw "Could not acquire the CODEX_HOME migration lock; another run may still be active: $lockPath"
    }
    Write-Diagnostic 'MIGRATION' "Migration lock acquired: $lockPath"
    try {
    Write-Diagnostic 'MIGRATION' 'Checking for incomplete migration ledgers.'
    Assert-NoIncompleteRunLedger $CodexDataHome
    Write-Diagnostic 'MIGRATION' 'Incomplete-ledger check passed.'
    Assert-ConversationAppsRemainClosed
    Assert-NotReparsePoint $ConfigPath 'config.toml'
    $configRead = Read-ConfigForForcedReplacement $ConfigPath
    Write-Diagnostic 'CONFIG' ("Read config snapshot: bytes={0}; sha256={1}" -f `
        $configRead.Snapshot.Length, (Get-ShortSha256 $configRead.Snapshot.Sha256))
    $rewrittenText = Rewrite-CodexConfig $configRead.Text $BaseUrl $ApiKey
    $rewrittenBytes = ConvertTo-Utf8Bytes $rewrittenText $false
    $rewrittenSha = Get-Sha256HexFromBytes $rewrittenBytes
    Write-Diagnostic 'CONFIG' ("Generated full managed replacement: output_bytes={0}; sha256={1}; raw config text is intentionally not printed." -f `
        $rewrittenBytes.Length, (Get-ShortSha256 $rewrittenSha))
    Write-Diagnostic 'CONFIG' "Default model enforced: $managedDefaultModel; reasoning effort enforced: $managedReasoningEffort; Ultra is not selected by this lightweight workflow."
    # Resolve an external SQLite store from the old config before that config
    # is replaced. The generated minimal config intentionally omits sqlite_home.
    $externalSqliteHome = Get-ExternalSqliteHomeForForcedReplacement $configRead.Text $CodexDataHome
    if ($null -eq $externalSqliteHome) {
        Write-Diagnostic 'MIGRATION' 'No external SQLite home will be migrated.'
    }
    else {
        Write-Diagnostic 'MIGRATION' "External SQLite home will be included: $externalSqliteHome"
    }

    $jsonlPaths = @(Get-JsonlPaths $CodexDataHome)
    Write-Diagnostic 'MIGRATION' "JSONL scan completed: $($jsonlPaths.Count) file(s)."
    for ($jsonlIndex = 0; $jsonlIndex -lt $jsonlPaths.Count; $jsonlIndex++) {
        Write-Diagnostic 'MIGRATION' "JSONL [$($jsonlIndex + 1)/$($jsonlPaths.Count)]: $($jsonlPaths[$jsonlIndex])"
    }

    $externalValue = if ($null -eq $externalSqliteHome) { '' } else { $externalSqliteHome }
    $databaseCandidates = @([CodexNativeSqlite]::GetCandidateDatabasePaths($CodexDataHome, $externalValue))
    $databasePaths = @(
        $databaseCandidates |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
            ForEach-Object { [IO.Path]::GetFullPath($_) } |
            Sort-Object -Unique
    )
    foreach ($databasePath in $databasePaths) {
        Assert-NotReparsePoint $databasePath 'SQLite state database'
        Write-Diagnostic 'MIGRATION' "SQLite state database selected: $databasePath"
    }
    Write-Diagnostic 'MIGRATION' "SQLite scan completed: $($databasePaths.Count) database(s)."

    $ledger = New-RunLedger $CodexDataHome $BaseUrl
    $ledger.Manifest.summary.jsonl_files_scanned = $jsonlPaths.Count
    $ledger.Manifest.summary.sqlite_databases_scanned = $databasePaths.Count
    Write-RunManifest $ledger
    $configChanged = $true
    Write-Diagnostic 'CONFIG' 'Forced config write required on every run: True; the previous file will be backed up first.'

    try {
        Set-LedgerStatus $ledger 'changing' ''
        if ($configChanged) {
            Assert-ConversationAppsRemainClosed
            $configBackup = Get-BackupPath $ledger 'config' $ConfigPath
            Write-Diagnostic 'CONFIG' "Creating verified config backup: $configBackup"
            Write-NewFileDurable $configBackup $configRead.Bytes
            $backupHash = (Get-FileSnapshot $configBackup).Sha256
            if ($backupHash -ne $configRead.Snapshot.Sha256) {
                throw "Config backup verification failed."
            }
            Write-Diagnostic 'CONFIG' ("Config backup verified: bytes={0}; sha256={1}" -f `
                $configRead.Snapshot.Length, (Get-ShortSha256 $backupHash))
            $configEntry = [ordered]@{
                kind = 'config'
                source = [IO.Path]::GetFullPath($ConfigPath)
                backup = $configBackup
                status = 'backed_up'
                before_sha256 = $configRead.Snapshot.Sha256
                after_sha256 = $rewrittenSha
            }
            Add-LedgerEntry $ledger $configEntry
            $configEntry.status = 'changing'
            Write-RunManifest $ledger
            Write-Diagnostic 'CONFIG' 'Replacing config.toml atomically.'
            Write-FileAtomic $ConfigPath $rewrittenBytes $configRead.Snapshot
            $writtenConfig = Get-FileSnapshot $ConfigPath
            if ($writtenConfig.Sha256 -ne $rewrittenSha) { throw "Config verification failed after replacement." }
            $configEntry.status = 'changed'
            Write-RunManifest $ledger
            Write-Diagnostic 'CONFIG' ("Config replacement verified: bytes={0}; sha256={1}" -f `
                $writtenConfig.Length, (Get-ShortSha256 $writtenConfig.Sha256))
        }
        else {
            throw 'Internal error: the forced config replacement path was unexpectedly disabled.'
        }

        # Each native Apply call takes its own exclusive handle, repeats
        # state/hash checks, creates and verifies the backup, atomically
        # replaces, and proves idempotence/non-provider byte identity.
        foreach ($path in $jsonlPaths) {
            Assert-ConversationAppsRemainClosed
            # Plan and apply one rollout at a time. A plan holds exact before and
            # after byte arrays, so pre-planning every history file can otherwise
            # require roughly twice the complete history size in memory. Any
            # later planning failure still rolls back earlier ledgered changes.
            Write-Diagnostic 'JSONL' "Planning provider-only migration: $path"
            $plan = [CodexLightweight.JsonlMigration]::PlanFile($path)
            if ($null -eq $plan) {
                Write-Diagnostic 'JSONL' "No provider change required (already custom or no session_meta): $path"
                continue
            }
            $providerList = @($plan.SourceProviders) -join ', '
            Write-Diagnostic 'JSONL' ("Plan ready: session_id={0}; provider_meta_lines={1}; source_providers=[{2}]" -f `
                $plan.CanonicalSessionId, $plan.ChangedMetaLines, $providerList)
            $backup = Get-BackupPath $ledger 'jsonl' ([string]$plan.FilePath)
            $entry = [ordered]@{
                kind = 'jsonl'
                source = [string]$plan.FilePath
                backup = $backup
                status = 'planned'
                before_sha256 = [string]$plan.BeforeSha256
                after_sha256 = [string]$plan.AfterSha256
                changed_meta_lines = [int]$plan.ChangedMetaLines
                source_providers = @($plan.SourceProviders)
            }
            Add-LedgerEntry $ledger $entry
            $entry.status = 'changing'
            Write-RunManifest $ledger
            Write-Diagnostic 'JSONL' "Applying atomic JSONL migration; backup=$backup"
            [CodexLightweight.JsonlMigration]::ApplyPlan($plan, $backup) | Out-Null
            $entry.status = 'changed'
            $ledger.Manifest.summary.jsonl_files_changed++
            $ledger.Manifest.summary.session_meta_lines_changed += [int]$plan.ChangedMetaLines
            Write-RunManifest $ledger
            Write-Diagnostic 'JSONL' "JSONL migration verified and recorded: $path"
        }

        foreach ($databasePath in $databasePaths) {
            Assert-ConversationAppsRemainClosed
            $backup = Get-BackupPath $ledger 'sqlite' $databasePath
            Write-Diagnostic 'SQLITE' "Planning SQLite provider migration: $databasePath"
            $entry = [ordered]@{
                kind = 'sqlite'
                source = $databasePath
                backup = $backup
                status = 'planned'
            }
            Add-LedgerEntry $ledger $entry
            $entry.status = 'changing'
            Write-RunManifest $ledger
            Write-Diagnostic 'SQLITE' "Opening SQLite transaction and verified online backup path: $backup"
            $result = [CodexNativeSqlite]::MigrateDatabase($databasePath, $backup, $sqliteBusyTimeoutMs)
            Write-Diagnostic 'SQLITE' ("SQLite result: threads_table={0}; total_threads={1}; provider_rows_changed={2}; backup_created={3}" -f `
                $result.ThreadsTablePresent, $result.TotalRows, $result.ChangedRows, (-not [string]::IsNullOrWhiteSpace([string]$result.BackupPath)))
            if ($result.ThreadsTablePresent -and $result.ChangedRows -gt 0) {
                $entry.expected_total_rows = [int64]$result.TotalRows
                $entry.expected_thread_ids_sha256 = [string]$result.ThreadIdsSha256
                $entry.expected_after_non_provider_sha256 = [string]$result.AfterNonProviderSha256
                $entry.expected_after_full_state_sha256 = [string]$result.AfterFullStateSha256
                $entry.before_full_state_sha256 = [string]$result.BeforeFullStateSha256
                $entry.backup_sha256 = (Get-FileSnapshot $backup).Sha256
                # Persist every recovery guard while the entry still says
                # changing. Only a second durable manifest promotes it to
                # changed, closing the result-to-ledger crash window.
                Write-RunManifest $ledger
                $entry.status = 'changed'
                $ledger.Manifest.summary.sqlite_rows_changed += [int]$result.ChangedRows
                Write-Diagnostic 'SQLITE' "SQLite migration verified and recorded: $databasePath"
            }
            else {
                $entry.status = 'unchanged'
                Write-Diagnostic 'SQLITE' "SQLite provider metadata already custom or threads table absent; no row update: $databasePath"
            }
            Write-RunManifest $ledger
        }

        # CC Switch may remain open. Detect a provider switch/config rewrite
        # after session migration; do not overwrite its newer configuration.
        $finalConfig = Read-Utf8FileStrict $ConfigPath
        Write-Diagnostic 'CONFIG' ("Final config snapshot read: bytes={0}; sha256={1}" -f `
            $finalConfig.Snapshot.Length, (Get-ShortSha256 $finalConfig.Snapshot.Sha256))
        if ($finalConfig.Snapshot.Sha256 -ne $rewrittenSha) {
            throw "CC Switch or another process changed config.toml during migration."
        }
        Assert-ManagedConfigShape $finalConfig.Text $BaseUrl $ApiKey
        Write-Diagnostic 'CONFIG' "Final config shape validation passed: custom + responses + requires_openai_auth=false; model=$managedDefaultModel; reasoning=$managedReasoningEffort; no env_key."
        Set-LedgerStatus $ledger 'complete' ''
        Write-Diagnostic 'MIGRATION' ("Migration completed: JSONL changed={0}; session_meta lines changed={1}; SQLite rows changed={2}" -f `
            $ledger.Manifest.summary.jsonl_files_changed, $ledger.Manifest.summary.session_meta_lines_changed, $ledger.Manifest.summary.sqlite_rows_changed)
        return [pscustomobject]@{
            Ledger = $ledger.Path
            ConfigChanged = $configChanged
            JsonlFilesScanned = $ledger.Manifest.summary.jsonl_files_scanned
            JsonlFilesChanged = $ledger.Manifest.summary.jsonl_files_changed
            SessionMetaLinesChanged = $ledger.Manifest.summary.session_meta_lines_changed
            SqliteDatabasesScanned = $ledger.Manifest.summary.sqlite_databases_scanned
            SqliteRowsChanged = $ledger.Manifest.summary.sqlite_rows_changed
        }
    }
    catch {
        $failure = $_.Exception.Message
        Write-Diagnostic 'MIGRATION' "Migration failure detected; invoking guarded rollback. Error: $failure"
        Invoke-RunRollback $ledger $failure
        throw
    }
    }
    finally {
        if ($null -ne $runLock) {
            $runLock.Dispose()
            Write-Diagnostic 'MIGRATION' "Migration lock released: $lockPath"
        }
    }
}

function Start-LightweightNativeEntry {
    $selectedHome = Select-CodexHomeForMigration
    $codexDataHome = [string]$selectedHome.Home
    $configPath = Join-Path $codexDataHome 'config.toml'
    Write-Diagnostic 'BOOT' ("Runtime: PowerShell={0}; user={1}; 64bit={2}; script={3}" -f `
        $PSVersionTable.PSVersion, $env:USERNAME, [Environment]::Is64BitProcess, $env:CODEX_LIGHTWEIGHT_SELF)
    Write-Diagnostic 'BOOT' "Provider endpoint selected; API key and config contents are intentionally never printed."

    Write-Host ''
    Write-Host 'Codex 全会话轻量统一（Windows 内置组件）' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "目标 CODEX_HOME ：$codexDataHome"
    Write-Host "发现的会话      ：JSONL $($selectedHome.JsonlFiles) 个；SQLite 线程 $($selectedHome.SqliteThreadRows) 条"
    if ($selectedHome.BootstrapNoSessions) {
        Write-Host '运行模式          ：首次安装配置（未发现旧会话，无需历史迁移）' -ForegroundColor Cyan
    }
    else {
        Write-Host '运行模式          ：全会话 provider 统一迁移' -ForegroundColor Cyan
    }
    Write-Host '目标 provider   ：custom'
    Write-Host "目标 Base URL   ：$managedBaseUrl"
    Write-Host '认证方式          ：config.toml 内置 experimental_bearer_token（无 env_key）'
    Write-Host '会话范围          ：sessions、archived_sessions、内置及外置 state_5.sqlite'
    Write-Host '配置策略          ：每次完整覆盖 config.toml；旧文件备份到本次迁移账本'
    Write-Host '不会修改          ：CC Switch 数据库、模型目录、Store/ASAR/MSIX、会话正文'
    Write-Host ''
    Write-Step '本次只会在本机修改配置和会话 provider 元数据，不会上传会话正文。'
    Write-Step 'Codex/ChatGPT/CC Switch 运行时可以先启动此脚本。确认后脚本会等待 Codex/ChatGPT 正常退出，不会强制结束进程。'
    if (@(Get-RunningCcSwitchProcesses).Count -gt 0) {
        Write-Step '检测到 CC Switch 正在运行；脚本完成前请勿切换 provider，脚本会检测并发配置改写。'
        Write-Diagnostic 'PROCESS' "CC Switch process(es): $((@(Get-RunningCcSwitchProcesses | ForEach-Object { $_.ProcessName + '#' + $_.Id }) -join ', '))"
    }
    $answer = (Read-Host '输入 Y 确认执行；其他输入取消').Trim()
    if ($answer -notin @('Y', 'y')) {
        Write-Step '用户取消，未做任何修改。'
        Write-Diagnostic 'BOOT' 'User cancelled before waiting for process exit or creating a migration ledger.'
        return 0
    }

    Write-Diagnostic 'BOOT' 'User confirmed migration; no write has occurred yet.'
    Wait-ForConversationApps
    Write-Step 'Codex/ChatGPT 已退出，开始安全备份、配置原子替换和会话迁移。'
    $result = Invoke-LightweightNativeMigration $codexDataHome $configPath $managedBaseUrl $managedApiKey

    Write-Host ''
    Write-Step "完成。迁移账本：$($result.Ledger)"
    if ($selectedHome.BootstrapNoSessions) {
        Write-Step "首次安装配置完成：未发现旧会话，因此 JSONL/SQLite 迁移均为 0；以后新建的会话会直接使用 custom。"
    }
    else {
        Write-Step "JSONL：扫描 $($result.JsonlFilesScanned)，修改 $($result.JsonlFilesChanged)；SQLite：扫描 $($result.SqliteDatabasesScanned)，行修改 $($result.SqliteRowsChanged)。"
    }
    Write-Step '最终为 custom + responses + requires_openai_auth=false，且 active custom 不依赖任何环境变量。'
    Write-Step "Default model: $managedDefaultModel; reasoning effort: $managedReasoningEffort. Ultra is not selected by the lightweight workflow."
    $elapsedSeconds = ([DateTime]::UtcNow - $script:lightweightStartedUtc).TotalSeconds
    Write-Diagnostic 'BOOT' ("Successful run elapsed: {0:N3} seconds." -f $elapsedSeconds)
    Write-Host ''
    Write-Host '================================================================' -ForegroundColor Yellow
    if ($selectedHome.BootstrapNoSessions) {
        Write-Host '  必须完全退出并重新启动 Codex/ChatGPT，新的 custom 配置才会生效。' -ForegroundColor Yellow
        Write-Host '  重启后请新建一条会话并发送消息，确认可正常使用第三方服务。' -ForegroundColor Yellow
    }
    else {
        Write-Host '  必须完全退出并重新启动 Codex/ChatGPT，配置和全部历史会话才会刷新。' -ForegroundColor Yellow
        Write-Host '  重启后请检查历史列表，并续聊一条旧会话确认仍写入原 session ID。' -ForegroundColor Yellow
    }
    Write-Host '================================================================' -ForegroundColor Yellow
    Write-Step '以后通过 CC Switch 切换 provider 会覆盖 live 配置，这是预期行为；所有会话仍统一在 custom 桶。'
    return 0
}

# The final BAT wrapper calls this after compiling both embedded C# payloads:
# try { exit (Start-LightweightNativeEntry) }
# catch { [Console]::Error.WriteLine("[codex-lightweight] ERROR: $($_.Exception.Message)"); exit 1 }

try {
    exit (Start-LightweightNativeEntry)
}
catch {
    Write-Host ''
    $record = $_
    $exception = $record.Exception
    $timestamp = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff')
    $elapsedSeconds = ([DateTime]::UtcNow - $script:lightweightStartedUtc).TotalSeconds
    [Console]::Error.WriteLine("[codex-lightweight][$timestamp][ERROR] $($exception.Message)")
    [Console]::Error.WriteLine("[codex-lightweight][$timestamp][DIAGNOSTIC TYPE] $($exception.GetType().FullName)")
    [Console]::Error.WriteLine("[codex-lightweight][$timestamp][ELAPSED] $([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:F3}', $elapsedSeconds)) seconds")
    if ($null -ne $record.InvocationInfo -and -not [string]::IsNullOrWhiteSpace($record.InvocationInfo.PositionMessage)) {
        $position = (($record.InvocationInfo.PositionMessage -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' | '
        [Console]::Error.WriteLine("[codex-lightweight][$timestamp][POSITION] $position")
    }
    $depth = 0
    while ($null -ne $exception.InnerException -and $depth -lt 3) {
        $exception = $exception.InnerException
        $depth++
        [Console]::Error.WriteLine("[codex-lightweight][$timestamp][INNER ${depth}] $($exception.GetType().FullName): $($exception.Message)")
    }
    if (-not [string]::IsNullOrWhiteSpace($record.ScriptStackTrace)) {
        $stack = (($record.ScriptStackTrace -split "`r?`n") | Select-Object -First 8) -join ' | '
        [Console]::Error.WriteLine("[codex-lightweight][$timestamp][STACK] $stack")
    }
    exit 1
}
