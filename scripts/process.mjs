import { spawn } from 'node:child_process'

export function spawnFile(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      ...options,
      stdio: options.stdio ?? ['ignore', 'pipe', 'pipe'],
    })
    let stdout = ''
    let stderr = ''
    if (child.stdout) child.stdout.on('data', (chunk) => (stdout += chunk))
    if (child.stderr) child.stderr.on('data', (chunk) => (stderr += chunk))
    child.on('error', reject)
    child.on('close', (code) => {
      if (code === 0) {
        resolve({ stdout, stderr })
      } else {
        const error = new Error(`${command} ${args.join(' ')} exited with ${code}`)
        error.stdout = stdout
        error.stderr = stderr
        reject(error)
      }
    })
  })
}
