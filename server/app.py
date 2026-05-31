import asyncio
import os
import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from openai import OpenAI
from pydantic import BaseModel
from typing import Dict

app = FastAPI()

# Configuração de CORS para permitir acesso do Flutter Web (GitHub Pages)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Configuração da API GROQ (A chave deve ser configurada nos 'Secrets' do Hugging Face)
GROQ_API_KEY = os.getenv("GROQ_API_KEY", "SUA_CHAVE_AQUI")
client_groq = OpenAI(base_url="https://api.groq.com/openai/v1", api_key=GROQ_API_KEY)
MODEL_NAME = "llama-3.3-70b-versatile"

# --- MODELOS DE DADOS ---

class VisionDetection(BaseModel):
    area_name: str
    object_type: str = "pessoa"
    severity: str = "high"

class CountingReport(BaseModel):
    location: str
    counts: Dict[str, int]
    timestamp: str

class HelperContext(BaseModel):
    event_type: str = "fall_detection"

# --- ENDPOINTS ---

@app.get('/')
async def root():
    return {"status": "online", "system": "TerlineT MediaPipe Core"}

@app.get('/explain_system')
async def explain_system():
    try:
        # Prompt atualizado para o novo motor MediaPipe
        prompt = (
            "Você é a TerlineT Eyes, uma IA de análise de fluxo de elite operando via MediaPipe Vision. "
            "Explique de forma curta (máximo 3 frases) e autoritária que o sistema agora utiliza "
            "modelos de detecção neural de alta precisão para monitorar e contar pessoas, veículos e ciclos "
            "em tempo real. Diga que a análise está operacional."
        )
        completion = client_groq.chat.completions.create(
            model=MODEL_NAME,
            messages=[{"role": "user", "content": prompt}],
            max_tokens=150
        )
        return {"message": completion.choices[0].message.content.strip()}
    except Exception:
        return {"message": "SISTEMA TERLINET EYES (MEDIAPIPE CORE) OPERACIONAL. PROTOCOLO DE CONTAGEM ATIVO. MONITORANDO FLUXO DE OBJETOS."}

@app.post('/analyze_counting')
async def analyze_counting(report: CountingReport):
    try:
        # Gera uma análise tática baseada nos números
        counts_str = ", ".join([f"{v} {k}(s)" for k, v in report.counts.items()])
        prompt = (
            f"Como TerlineT Eyes, realize uma análise tática rápida para a localização {report.location}. "
            f"Dados coletados: {counts_str}. "
            "Forneça uma conclusão de segurança ou logística em no máximo 2 frases curtas e técnicas."
        )
        completion = client_groq.chat.completions.create(
            model=MODEL_NAME,
            messages=[{"role": "user", "content": prompt}],
            max_tokens=100
        )
        return {"analysis": completion.choices[0].message.content.strip()}
    except Exception:
        return {"analysis": "ANÁLISE TÁTICA CONCLUÍDA: Fluxo dentro dos parâmetros operacionais. Monitoramento contínuo ativo."}

@app.post('/vision_alert')
async def vision_alert(v: VisionDetection):
    try:
        prompt = (
            f"TerlineT Eyes detectou {v.object_type} em {v.area_name}. "
            f"Aborde o invasor de forma curta e autoritária para dissuasão."
        )
        completion = client_groq.chat.completions.create(
            model=MODEL_NAME,
            messages=[{"role": "user", "content": prompt}],
            max_tokens=60
        )
        return {"message": completion.choices[0].message.content.strip()}
    except Exception:
        return {"message": "ALERTA: Atividade detectada no perímetro monitorado. Sistema em prontidão."}

@app.get('/defense_intro')
async def defense_intro():
    try:
        prompt = "Diga de forma tática que o sistema de defesa TerlineT está online com motor MediaPipe e miras calibradas."
        completion = client_groq.chat.completions.create(
            model=MODEL_NAME,
            messages=[{"role": "user", "content": prompt}],
            max_tokens=100
        )
        return {"message": completion.choices[0].message.content.strip()}
    except Exception:
        return {"message": "Sistema de defesa TerlineT operacional. Análise de profundidade ativa. Perímetro sob custódia."}

@app.get('/helper_intro')
async def helper_intro():
    try:
        prompt = "Você é o TerlineT Helper operando via MediaPipe. Apresente-se de forma curta, elegante e protetora."
        completion = client_groq.chat.completions.create(
            model=MODEL_NAME,
            messages=[{"role": "user", "content": prompt}],
            max_tokens=100
        )
        return {"message": completion.choices[0].message.content.strip()}
    except Exception:
        return {"message": "Olá. Sou o seu Helper TerlineT. Utilizo visão neural avançada para garantir sua segurança e bem-estar."}

if __name__ == "__main__":
    # Hugging Face Spaces exige a porta 7860
    uvicorn.run(app, host="0.0.0.0", port=7860)