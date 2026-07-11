/*
 * Copyright (c) 2018, Adam <Adam@sigterm.info>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
#version 330

#define SAMPLING_MODE 0

#define SAMPLING_NEAREST 0
#define SAMPLING_LINEAR 1
#define SAMPLING_MITCHELL 2
#define SAMPLING_CATROM 3
#define SAMPLING_XBR 4
#define SAMPLING_HYBRID 5

uniform ivec2 sourceDimensions;
uniform ivec2 targetDimensions;

layout(location = 0) in vec3 aPos;
layout(location = 1) in vec2 aTexCoord;

out vec2 TexCoord;
#if SAMPLING_MODE == SAMPLING_XBR
/*
   Hyllian's xBR-lv2 Shader

   Copyright (C) 2011-2016 Hyllian - sergiogdb@gmail.com

   Permission is hereby granted, free of charge, to any person obtaining a copy
   of this software and associated documentation files (the "Software"), to deal
   in the Software without restriction, including without limitation the rights
   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
   copies of the Software, and to permit persons to whom the Software is
   furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in
   all copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
   THE SOFTWARE.

   Incorporates some of the ideas from SABR shader. Thanks to Joshua Street.
*/

/*
   Hyllian's xBR-lv2 Shader

   Copyright (C) 2011-2016 Hyllian - sergiogdb@gmail.com

   Permission is hereby granted, free of charge, to any person obtaining a copy
   of this software and associated documentation files (the "Software"), to deal
   in the Software without restriction, including without limitation the rights
   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
   copies of the Software, and to permit persons to whom the Software is
   furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in
   all copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
   THE SOFTWARE.

   Incorporates some of the ideas from SABR shader. Thanks to Joshua Street.
*/

struct XBRTable {
  vec2 texCoord;
  vec4 t1;
  vec4 t2;
  vec4 t3;
  vec4 t4;
  vec4 t5;
  vec4 t6;
  vec4 t7;
};

XBRTable xbr_vert(vec2 texCoord, ivec2 sourceDimensions) {
  float dx = (1.0 / sourceDimensions.x);
  float dy = (1.0 / sourceDimensions.y);

  // Define coordinates to optimize later fetching of adjacent pixels
  //    A1 B1 C1
  // A0  A  B  C C4
  // D0  D  E  F F4
  // G0  G  H  I I4
  //    G5 H5 I5
  XBRTable tab = XBRTable(texCoord, texCoord.xxxy + vec4(-dx, 0, dx, -2.0 * dy),  // A1 B1 C1
                          texCoord.xxxy + vec4(-dx, 0, dx, -dy),                  //  A  B  C
                          texCoord.xxxy + vec4(-dx, 0, dx, 0),                    //  D  E  F
                          texCoord.xxxy + vec4(-dx, 0, dx, dy),                   //  G  H  I
                          texCoord.xxxy + vec4(-dx, 0, dx, 2.0 * dy),             // G5 H5 I5
                          texCoord.xyyy + vec4(-2.0 * dx, -dy, 0, dy),            // A0 D0 G0
                          texCoord.xyyy + vec4(2.0 * dx, -dy, 0, dy)              // C4 F4 I4
  );

  tab.texCoord.x *= 1.00000001;

  return tab;
}

out XBRTable xbrTable;
#endif

void main() {
  gl_Position = vec4(aPos, 1.0);
  TexCoord = aTexCoord;

#if SAMPLING_MODE == SAMPLING_XBR
  xbrTable = xbr_vert(TexCoord, sourceDimensions);
#endif
}
