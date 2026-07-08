import OpenGLES
import UIKit

struct GLVertexAttribute {
  let location: GLint
  let size: GLint
  let offsetBytes: Int
}

enum GLHelper {
  static func buildProgram(
    vertexSource: String,
    fragmentSource: String
  ) -> GLuint {
    let vertex = compileShader(type: GLenum(GL_VERTEX_SHADER), source: vertexSource)
    let fragment = compileShader(type: GLenum(GL_FRAGMENT_SHADER), source: fragmentSource)
    guard vertex != 0, fragment != 0 else { return 0 }

    let program = glCreateProgram()
    glAttachShader(program, vertex)
    glAttachShader(program, fragment)
    glLinkProgram(program)

    var status: GLint = 0
    glGetProgramiv(program, GLenum(GL_LINK_STATUS), &status)
    if status == GL_FALSE {
      print("[GLEffect] program link failed:", programLog(program))
      glDeleteProgram(program)
      glDeleteShader(vertex)
      glDeleteShader(fragment)
      return 0
    }

    glDetachShader(program, vertex)
    glDetachShader(program, fragment)
    glDeleteShader(vertex)
    glDeleteShader(fragment)
    return program
  }

  private static func compileShader(type: GLenum, source: String) -> GLuint {
    let shader = glCreateShader(type)
    var cString = (source as NSString).utf8String
    var length = GLint(source.utf8.count)
    glShaderSource(shader, 1, &cString, &length)
    glCompileShader(shader)

    var status: GLint = 0
    glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &status)
    if status == GL_FALSE {
      print("[GLEffect] shader compile failed:", shaderLog(shader))
      glDeleteShader(shader)
      return 0
    }
    return shader
  }

  private static func shaderLog(_ shader: GLuint) -> String {
    var length: GLint = 0
    glGetShaderiv(shader, GLenum(GL_INFO_LOG_LENGTH), &length)
    guard length > 1 else { return "unknown error" }
    var bytes = [GLchar](repeating: 0, count: Int(length))
    glGetShaderInfoLog(shader, length, nil, &bytes)
    return String(cString: bytes)
  }

  private static func programLog(_ program: GLuint) -> String {
    var length: GLint = 0
    glGetProgramiv(program, GLenum(GL_INFO_LOG_LENGTH), &length)
    guard length > 1 else { return "unknown error" }
    var bytes = [GLchar](repeating: 0, count: Int(length))
    glGetProgramInfoLog(program, length, nil, &bytes)
    return String(cString: bytes)
  }

  static func drawInterleaved(
    buffer: GLFloatBuffer,
    strideBytes: Int,
    attributes: [GLVertexAttribute],
    mode: GLenum,
    vertexCount: Int
  ) {
    guard vertexCount > 0 else { return }
    _ = buffer.withUnsafeRawPointer { base, _ in
      for attribute in attributes where attribute.location >= 0 {
        glEnableVertexAttribArray(GLuint(attribute.location))
        glVertexAttribPointer(
          GLuint(attribute.location),
          attribute.size,
          GLenum(GL_FLOAT),
          GLboolean(GL_FALSE),
          GLsizei(strideBytes),
          base.advanced(by: attribute.offsetBytes)
        )
      }
      glDrawArrays(mode, 0, GLsizei(vertexCount))
      for attribute in attributes where attribute.location >= 0 {
        glDisableVertexAttribArray(GLuint(attribute.location))
      }
    }
  }

  static func segNormal(
    _ x1: Float,
    _ y1: Float,
    _ x2: Float,
    _ y2: Float
  ) -> (Float, Float) {
    let dx = x2 - x1
    let dy = y2 - y1
    let length = max(sqrt(dx * dx + dy * dy), 0.000_001)
    return (-dy / length, dx / length)
  }

  static func avgNormal(
    _ x0: Float,
    _ y0: Float,
    _ x1: Float,
    _ y1: Float,
    _ x2: Float,
    _ y2: Float
  ) -> (Float, Float) {
    let n1 = segNormal(x0, y0, x1, y1)
    let n2 = segNormal(x1, y1, x2, y2)
    let nx = n1.0 + n2.0
    let ny = n1.1 + n2.1
    let length = max(sqrt(nx * nx + ny * ny), 0.000_001)
    return (nx / length, ny / length)
  }

  static func rgba(_ color: UIColor) -> (Float, Float, Float, Float) {
    var r: CGFloat = 1
    var g: CGFloat = 1
    var b: CGFloat = 1
    var a: CGFloat = 1
    if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
      return (Float(r), Float(g), Float(b), Float(a))
    }
    var white: CGFloat = 1
    color.getWhite(&white, alpha: &a)
    return (Float(white), Float(white), Float(white), Float(a))
  }

  static func vivid(_ color: UIColor) -> UIColor {
    var h: CGFloat = 0
    var s: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 1
    guard color.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
      return color
    }
    return UIColor(hue: h, saturation: max(s, 0.85), brightness: 1, alpha: a)
  }

  static func hueShift(_ color: UIColor, degrees: CGFloat) -> UIColor {
    var h: CGFloat = 0
    var s: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 1
    guard color.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
      return color
    }
    let shifted = (h + degrees / 360).truncatingRemainder(dividingBy: 1)
    return UIColor(
      hue: shifted < 0 ? shifted + 1 : shifted,
      saturation: max(s, 0.85), brightness: 1, alpha: a)
  }

  static func normalizedPosition(_ point: CGPoint) -> (Float, Float) {
    (Float(point.x * 2 - 1), Float(1 - point.y * 2))
  }

  static func randomFloat(_ range: ClosedRange<Float> = 0...1) -> Float {
    Float.random(in: range)
  }
}

extension Float {
  func glClamped(_ lower: Float = 0, _ upper: Float = 1) -> Float {
    min(max(self, lower), upper)
  }
}
